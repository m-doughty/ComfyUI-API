unit module ComfyUI::API::Exception;

class X::ComfyUI::IntrospectionMissing is Exception is export {
	has Str:D $.node-class is required;
	has Str:D $.field is required;
	method message(--> Str:D) {
		"ComfyUI introspection missing: node class '$!node-class' has no required field '$!field'. " ~
			"Is your ComfyUI install missing a custom node, or is the server too old?";
	}
}

#|( Thrown by C<ComfyUI::API::Client.download> when the HTTP body
    fetch does not complete within the configured timeout. Cro's
    HTTP client doesn't surface a body-read timeout itself, so a
    server that opens the connection and then stalls mid-stream
    leaves the C<await $resp.body-blob> permanently pending. The
    download wraps the fetch in a C<Promise.anyof> with a timeout
    Promise and throws this when the timeout wins, so callers get
    a real exception instead of a silent hang. )
class X::ComfyUI::DownloadTimeout is Exception is export {
	has Str:D $.filename is required;
	has Num:D $.timeout  is required;
	method message(--> Str:D) {
		"ComfyUI download timed out after {$!timeout}s (filename=$!filename). " ~
			"The HTTP body never finished streaming — ComfyUI may be stalled, " ~
			"network is dropping packets, or the output file is missing on disk.";
	}
}
