use Cro::HTTP::Client;
use JSON::Fast;
use UUID::V4;
use ComfyUI::API::Workflow;
use ComfyUI::API::Result;

unit class ComfyUI::API::Client;

has Str:D $.base-url = 'http://127.0.0.1:8188';
has Str $.client-id;

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
