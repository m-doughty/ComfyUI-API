unit module ComfyUI::API::Exception;

class X::ComfyUI::IntrospectionMissing is Exception is export {
	has Str:D $.node-class is required;
	has Str:D $.field is required;
	method message(--> Str:D) {
		"ComfyUI introspection missing: node class '$!node-class' has no required field '$!field'. " ~
			"Is your ComfyUI install missing a custom node, or is the server too old?";
	}
}
