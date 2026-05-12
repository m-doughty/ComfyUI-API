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

method submit(ComfyUI::API::Workflow:D $workflow --> Str:D) {
	my %body = %(
		prompt    => $workflow.to-hash,
		client_id => $!client-id,
	);

	my $client = Cro::HTTP::Client.new(:content-type<application/json>);
	my $resp = await $client.post("$!base-url/prompt",
		:body(to-json(%body)),
	);
	my $json = await $resp.body-text;
	my %result = from-json($json);

	die "ComfyUI::API::Client: prompt rejected: {%result<error> // 'unknown error'}"
		if %result<error>:exists;

	%result<prompt_id> // die "ComfyUI::API::Client: no prompt_id in response";
}

method poll(Str:D $prompt-id, Num:D :$timeout = 300e0, Num:D :$interval = 1e0 --> ComfyUI::API::Result:D) {
	my $client = Cro::HTTP::Client.new;
	my Instant $deadline = now + $timeout;

	loop {
		my $resp = await $client.get("$!base-url/history/$prompt-id");
		my $json = await $resp.body-text;
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

method download(Str:D $filename, Str :$subfolder = '', Str :$type = 'output' --> Buf:D) {
	my $client = Cro::HTTP::Client.new;
	my $url = "$!base-url/view?filename=$filename&subfolder=$subfolder&type=$type";
	my $resp = await $client.get($url);
	await $resp.body-blob;
}

method queue-status(--> Hash) {
	my $client = Cro::HTTP::Client.new;
	my $resp = await $client.get("$!base-url/queue");
	my $json = await $resp.body-text;
	from-json($json);
}

method node-info(--> Hash) {
	my $client = Cro::HTTP::Client.new;
	my $resp = await $client.get("$!base-url/object_info");
	my $json = await $resp.body-text;
	from-json($json);
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
