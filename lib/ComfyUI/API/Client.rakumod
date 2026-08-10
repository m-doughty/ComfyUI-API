use Cro::HTTP::Client;
use Cro::WebSocket::Client;
use JSON::Fast;
use UUID::V4;
use ComfyUI::API::Workflow;
use ComfyUI::API::Result;
use ComfyUI::API::Exception;

unit class ComfyUI::API::Client;

has Str:D $.base-url = 'http://127.0.0.1:8188';
has Str $.client-id;

has Supplier $!progress-supplier;
has Bool     $!progress-started = False;
has Lock     $!progress-lock = Lock.new;

submethod TWEAK() {
	$!client-id //= uuid-v4();
}

#|( Decode response bytes as text ourselves rather than letting Cro
    do it.

    Cro asks C<body-text-encoding> for an encoding, and when the
    Content-Type names no charset that method returns the LIST
    C<('utf-8', 'latin-1')> (Cro::HTTP::Message). C<body-text> in
    Cro::MessageWithBody then loops over that list with no C<last>, so
    the latin-1 attempt — which cannot fail, whatever the bytes are —
    always overwrites the successful utf-8 decode. Every charset-less
    response therefore came back as mojibake: café -> cafÃ©.

    Every text body this client reads is JSON, and JSON is UTF-8 by
    definition (RFC 8259 §8.1), so utf-8 is the only correct reading
    of one. That matters here because ComfyUI echoes the submitted
    workflow back out of C</history>: the payload carries the prompt
    text verbatim, alongside node titles, checkpoint / LoRA filenames
    and Python exception messages, all of which routinely contain
    non-ASCII. Whether the charset is present at all is not something
    a client can rely on — custom nodes register their own aiohttp
    routes, and installs are commonly fronted by a reverse proxy or
    tunnel that rewrites headers.

    latin-1 survives only as a fallback for the non-JSON page such a
    proxy might answer with, and is reached only when the utf-8 decode
    throws — never in preference to a decode that worked.

    Never throws: an undefined, empty or undecodable blob all read as
    the empty string. )
method _blob-text($blob --> Str:D) {
	# Untyped on purpose — callers hand us whatever the body await
	# produced, and this is the helper that must not itself be the
	# thing that throws.
	return '' unless $blob ~~ Blob:D;
	(try $blob.decode('utf-8')) // (try $blob.decode('latin-1')) // '';
}

#|( C<_blob-text> over a whole response.

    Unlike C<_blob-text> this B<does> propagate: C<await .body-blob>
    is deliberately left bare so a connection dropped mid-body still
    surfaces as the transport exception C<poll>'s stall handling is
    written against, rather than collapsing into an empty string that
    C<from-json> would then report as a bogus parse failure.

    Note this reads the raw bytes rather than C<await .body>, which
    routes through Cro's body-parser selector and so reaches the JSON
    parser only while the server labels the payload
    C<application/json> — a body labelled C<text/plain> lands on
    Cro's text fallback (mojibake again), and an unlabelled one on the
    blob fallback, handing back a Buf that the callers below would
    then index as a Hash and silently read as empty. Parsing the
    bytes ourselves makes the result depend on the payload rather
    than on a header. )
method _body-text($resp --> Str:D) {
	self._blob-text(await $resp.body-blob);
}

method submit(ComfyUI::API::Workflow:D $workflow --> Str:D) {
	my %body = %(
		prompt    => $workflow.to-hash,
		client_id => $!client-id,
	);

	my $client = Cro::HTTP::Client.new(:content-type<application/json>);
	my $resp = await $client.post("$!base-url/prompt",
		:body(to-json(%body)),
	);
	my $json = self._body-text($resp);
	my %result = from-json($json);

	die "ComfyUI::API::Client: prompt rejected: {%result<error> // 'unknown error'}"
		if %result<error>:exists;

	%result<prompt_id> // die "ComfyUI::API::Client: no prompt_id in response";
}

#|( Long-poll ComfyUI's C</history/$prompt-id> endpoint until the
    prompt's row appears (sampling finished, outputs ready) or
    C<:timeout> seconds elapse. Each individual HTTP call is raced
    against the remaining deadline via C<Promise.anyof> — Cro's
    client has no built-in body-read timeout, so a stalled
    connection inside C<await $client.get> or the body read in
    C<_body-text> would otherwise hang forever and the loop's own
    deadline check sits B<after> those awaits. The per-call race
    converts a hung
    request into a thrown timeout in bounded time, letting callers
    (the orchestrator's outer CATCH) treat the failure as a regular
    error instead of a silent stall. )
method poll(Str:D $prompt-id, Num:D :$timeout = 300e0, Num:D :$interval = 1e0 --> ComfyUI::API::Result:D) {
	my $client = Cro::HTTP::Client.new;
	my Instant $deadline = now + $timeout;

	loop {
		# Per-request budget: at least 0.5s so very-short outer
		# timeouts (the safety-net poll uses 0.1s) still get one
		# real attempt, capped at the remaining deadline so we
		# don't outlast our own caller. Without the floor, an
		# already-expired deadline would set $remaining to ~0 and
		# Promise.in(0) would fire before $req's start block could
		# even begin running.
		my Num $remaining = max(($deadline - now), 0.5e0).Num;
		my $req = start {
			my $resp = await $client.get("$!base-url/history/$prompt-id");
			self._body-text($resp);
		};
		await Promise.anyof($req, Promise.in($remaining));

		my Str $json;
		if $req.status ~~ Kept {
			$json = $req.result;
		} elsif $req.status ~~ Broken {
			# Network / HTTP error from the start block. Re-raising
			# via $req.result keeps the original exception so the
			# orchestrator log can identify the failure mode.
			$req.result;
		} else {
			die "ComfyUI::API::Client: HTTP request to /history/$prompt-id stalled mid-flight (no response within {$remaining.fmt('%.1f')}s); the request was abandoned and the overall poll timeout ({$timeout}s) won";
		}

		my %history = from-json($json);

		if %history{$prompt-id}:exists {
			return ComfyUI::API::Result.new(
				:$prompt-id,
				:data(%history{$prompt-id}),
			);
		}

		if now > $deadline {
			die "ComfyUI::API::Client: timed out waiting for prompt $prompt-id after {$timeout}s";
		}

		sleep $interval;
	}
}

method submit-and-wait(ComfyUI::API::Workflow:D $workflow, Num:D :$timeout = 300e0, Num:D :$interval = 1e0 --> ComfyUI::API::Result:D) {
	my Str:D $prompt-id = self.submit($workflow);
	self.poll($prompt-id, :$timeout, :$interval);
}

#|( Fetch a generated image's bytes from C</view>. The body fetch is
    raced against a C<Promise.in($timeout)> so a stalled connection
    (ComfyUI never finishes streaming, dropped packets after the
    headers arrive, output file missing on disk so the server hangs
    on read) surfaces as an C<X::ComfyUI::DownloadTimeout> instead
    of a permanent C<await>. Cro::HTTP::Client doesn't expose a
    body-read timeout itself, which is why we race at the call site
    rather than configuring the client. C<:timeout> defaults to 60s
    \x{2014} healthy ComfyUI on LAN delivers a high-res PNG sub-second,
    so 60s is generous enough to cover slow first-byte without
    leaving the user staring at a frozen card.

    =head2 Example
    =begin code :lang<raku>
    my $client = ComfyUI::API::Client.new;
    my Buf $bytes = try $client.download('out.png');
    if $! ~~ X::ComfyUI::DownloadTimeout {
        # Surface the stall to the user; the card can flip to 'error'
        # with the message and they can retry the generation.
        note $!.message;
    }
    =end code )
method download(Str:D $filename, Str :$subfolder = '', Str :$type = 'output',
                Num:D :$timeout = 60e0 --> Buf:D) {
	my $client = Cro::HTTP::Client.new;
	my $url = "$!base-url/view?filename=$filename&subfolder=$subfolder&type=$type";
	my $fetch = start {
		my $resp = await $client.get($url);
		await $resp.body-blob;
	};
	my $deadline = Promise.in($timeout);
	await Promise.anyof($fetch, $deadline);
	if $fetch.status ~~ Kept {
		return $fetch.result;
	}
	if $fetch.status ~~ Broken {
		# Network / HTTP error finished before the timeout — surface
		# the original exception rather than reporting a timeout we
		# didn't actually hit.
		$fetch.result;
	}
	die X::ComfyUI::DownloadTimeout.new(:$filename, :$timeout);
}

method queue-status(--> Hash) {
	my $client = Cro::HTTP::Client.new;
	my $resp = await $client.get("$!base-url/queue");
	from-json(self._body-text($resp));
}

#|( Cancel a currently-executing prompt. Pass C<$prompt-id> for the
    targeted frontend-compatible shape C<POST /interrupt
    {"prompt_id":"..."}>. Calling without an id retains the older
    global interrupt behaviour for callers that explicitly want it.
    Returns silently on success; logs to STDERR on failure (network
    down, auth, etc.) so a stuck or unreachable ComfyUI never blocks
    the caller. Pair with C<delete-from-queue> when you have a
    specific C<prompt_id> in mind: C<delete-from-queue> removes a
    prompt that is queued-but-not-yet-running; targeted C<interrupt>
    kills that prompt if it is running. Firing both is the safe play
    when you don't know which state your prompt is in.

    =head2 Example
    =begin code :lang<raku>
    my $client = ComfyUI::API::Client.new(base-url => 'http://localhost:8188');
    my $prompt-id = $client.submit($workflow);
    # ... user changes their mind ...
    $client.delete-from-queue($prompt-id);
    $client.interrupt($prompt-id);
    =end code )
method interrupt(Str $prompt-id? --> Nil) {
	try {
		my $http = Cro::HTTP::Client.new(:content-type<application/json>);
		my %body = $prompt-id.defined && $prompt-id.chars
			?? %( prompt_id => $prompt-id )
			!! %();
		await $http.post("$!base-url/interrupt", :body(to-json(%body)));
		CATCH {
			default {
				note "ComfyUI::API::Client.interrupt failed: $_";
			}
		}
	}
}

#|( Delete a specific prompt from the ComfyUI queue. Targets a prompt
    that has been C<submit>ted but has not yet started sampling.
    Quietly no-ops on an empty C<$prompt-id> (caller may not have
    received an id yet — e.g. cancel fires during the LLM prompt-gen
    phase, before the workflow is submitted to ComfyUI).

    Errors (4xx if the id is unknown, network failure, etc.) are
    logged to STDERR and absorbed; this method is intended for fire-
    and-forget use from cancel handlers.

    =head2 Example
    =begin code :lang<raku>
    $client.delete-from-queue($prompt-id);
    =end code )
method delete-from-queue(Str:D $prompt-id --> Nil) {
	# `without` would be wrong here — .chars returns 0 for empty
	# strings, and 0 is defined. `unless` short-circuits cleanly on
	# the zero-length case (and on the unlikely Nil-coerced-to-Str).
	return unless $prompt-id.chars;
	try {
		my $http = Cro::HTTP::Client.new(:content-type<application/json>);
		await $http.post("$!base-url/queue",
			:body(to-json({ delete => [$prompt-id] })));
		CATCH {
			default {
				note "ComfyUI::API::Client.delete-from-queue($prompt-id) failed: $_";
			}
		}
	}
}

method node-info(--> Hash) {
	my $client = Cro::HTTP::Client.new;
	my $resp = await $client.get("$!base-url/object_info");
	from-json(self._body-text($resp));
}

method health(Num:D :$timeout = 3e0 --> Bool:D) {
	my $client = Cro::HTTP::Client.new;

	my $req = start {
		try {
			my $resp = await $client.get("$!base-url/system_stats");
			$resp.status == 200
		} // False
	};

	await Promise.anyof($req, Promise.in($timeout));

	$req.status ~~ Kept ?? so $req.result !! False;
}

method list-checkpoints(:$info --> List) {
	my %i = $info // self.node-info;
	self!introspect-enum(%i, 'CheckpointLoaderSimple', 'ckpt_name');
}

method list-loras(:$info --> List) {
	my %i = $info // self.node-info;
	self!introspect-enum(%i, 'LoraLoader', 'lora_name');
}

method list-samplers(:$info --> List) {
	my %i = $info // self.node-info;
	self!introspect-enum(%i, 'KSampler', 'sampler_name');
}

method list-schedulers(:$info --> List) {
	my %i = $info // self.node-info;
	self!introspect-enum(%i, 'KSampler', 'scheduler');
}

method list-vaes(:$info --> List) {
	my %i = $info // self.node-info;
	self!introspect-enum(%i, 'VAELoader', 'vae_name');
}

#| Unet / diffusion-model files exposed by ComfyUI. CheckpointLoaderSimple
#| only sees `.safetensors` baked-bundle checkpoints (SDXL, SD1.5, Pony,
#| Illustrious, NoobAI). Flux / SD3 / Sana variants are usually shipped
#| as standalone UNet files: GGUF quants (loaded via the ComfyUI-GGUF
#| custom node, node class C<UnetLoaderGGUF>) and fp8 / fp16 safetensors
#| (loaded via the built-in C<UNETLoader>). Both feed the same
#| C<unet_name> enum field on their respective loaders, so we union them
#| into one list.
#|
#| Installations vary — not every ComfyUI install has the GGUF custom
#| node, and very old builds may not have UNETLoader either. Each
#| introspection is wrapped in C<try> so a missing node contributes
#| an empty list rather than throwing the whole call.
method list-unets(:$info --> List) {
	my %i = $info // self.node-info;
	my @combined;
	for <UnetLoaderGGUF UNETLoader> -> $node-class {
		@combined.append:
			|( (try self!introspect-enum(%i, $node-class, 'unet_name')) // () );
	}
	@combined.unique.sort.list;
}

#| CLIP model names exposed by DualCLIPLoader (Flux / SD3 dual-encoder
#| setup needs clip_l + t5xxl picked separately). C<try>-wrapped:
#| installations without DualCLIPLoader simply contribute nothing.
method list-clips(:$info --> List) {
	my %i = $info // self.node-info;
	my @combined;
	for <clip_name1 clip_name2> -> $field {
		@combined.append:
			|( (try self!introspect-enum(%i, 'DualCLIPLoader', $field)) // () );
	}
	@combined.unique.sort.list;
}

method progress-supply(--> Supply:D) {
	$!progress-lock.protect: {
		unless $!progress-started {
			$!progress-supplier = Supplier.new;
			$!progress-started = True;
			self!start-progress-worker;
		}
	}
	$!progress-supplier.Supply;
}

method parse-progress-message(%msg --> Hash) {
	# Pure parser: takes a decoded ComfyUI WS message hash, returns the typed
	# event hash to emit, or {} for messages we don't surface (binary previews,
	# heartbeats, unrecognized types).
	my Str $type = (%msg<type> // '').Str;
	my %data = (%msg<data> // %{}).Hash;

	given $type {
		when 'status' {
			my $exec = %data<status><exec_info> // %{};
			return %(
				type    => 'queue',
				pending => ($exec<queue_remaining> // 0).Int,
				running => 0,
			);
		}
		when 'execution_start' {
			return %(
				type      => 'execution-start',
				prompt-id => (%data<prompt_id> // '').Str,
			);
		}
		when 'executing' {
			my $node = %data<node>;
			if $node.defined {
				return %(
					type      => 'executing',
					prompt-id => (%data<prompt_id> // '').Str,
					node      => $node.Str,
				);
			}
			else {
				# In the older protocol, a null `node` on `executing` signals end.
				return %(
					type      => 'execution-end',
					prompt-id => (%data<prompt_id> // '').Str,
				);
			}
		}
		when 'progress' {
			return %(
				type      => 'progress',
				prompt-id => (%data<prompt_id> // '').Str,
				value     => (%data<value> // 0).Int,
				max       => (%data<max>   // 0).Int,
				node      => (%data<node>  // '').Str,
			);
		}
		when 'executed' {
			return %(
				type      => 'executed',
				prompt-id => (%data<prompt_id> // '').Str,
				node      => (%data<node>      // '').Str,
				output    => (%data<output>    // %{}).Hash,
			);
		}
		when 'execution_success' {
			return %(
				type      => 'execution-end',
				prompt-id => (%data<prompt_id> // '').Str,
			);
		}
		when 'execution_error' {
			return %(
				type      => 'error',
				prompt-id => (%data<prompt_id>         // '').Str,
				message   => (%data<exception_message> // 'Unknown error').Str,
				node      => (%data<node_id>           // '').Str,
			);
		}
		default {
			return %{};
		}
	}
}

method !start-progress-worker(--> Nil) {
	my Str $ws-url = $!base-url.subst(/^ 'http' /, 'ws') ~ "/ws?clientId=$!client-id";

	start {
		loop {
			try {
				my $client = Cro::WebSocket::Client.new(:uri($ws-url));
				my $conn   = await $client.connect;

				react {
					whenever $conn.messages -> $msg {
						LAST { done }
						next unless $msg.is-text;
						try {
							# Not the charset-less-HTTP hazard _blob-text
							# exists for: Cro::WebSocket::Message.body-text-encoding
							# answers the single Str 'utf-8' for a text
							# frame (RFC 6455 mandates UTF-8), so body-text
							# takes the single-encoding branch and never
							# reaches the latin-1-overwrites-utf-8 loop.
							my $text    = await $msg.body-text;
							my %decoded = from-json($text);
							my %event   = self.parse-progress-message(%decoded);
							$!progress-supplier.emit(%event) if %event.elems;
							CATCH { default {} }  # swallow per-message decode errors
						}
					}
				}

				CATCH { default {} }  # connect / react failures fall through to reconnect
			}
			# Brief pause before reconnect so we don't spin on a dead server.
			sleep 1;
		}
	}
}

method !introspect-enum(%info, Str:D $node-class, Str:D $field --> List) {
	my $class-info = %info{$node-class}
		// X::ComfyUI::IntrospectionMissing.new(:$node-class, :$field).throw;

	my $required = $class-info<input><required>
		// X::ComfyUI::IntrospectionMissing.new(:$node-class, :$field).throw;

	my $field-spec = $required{$field}
		// X::ComfyUI::IntrospectionMissing.new(:$node-class, :$field).throw;

	# /object_info enum fields are [[value1, value2, ...], { metadata }]
	# Non-enum fields are ["TYPE", { metadata }] — no value list. Treat as missing.
	my $values = $field-spec[0];
	return ($values ~~ Iterable ?? $values.unique.sort !! ()).list;
}
