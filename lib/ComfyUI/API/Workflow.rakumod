use JSON::Fast;

unit class ComfyUI::API::Workflow;

has %!data;

submethod BUILD(:%!data) {}

method from-file(IO::Path:D $path --> ComfyUI::API::Workflow:D) {
	self.from-json($path.slurp);
}

method from-json(Str:D $json --> ComfyUI::API::Workflow:D) {
	self.from-hash(from-json($json));
}

method from-hash(%data --> ComfyUI::API::Workflow:D) {
	self.new(:%data);
}

method set(Str:D $node-id, Str:D $field, $value --> Nil) {
	die "ComfyUI::API::Workflow: node '$node-id' not found"
		unless %!data{$node-id}:exists;
	die "ComfyUI::API::Workflow: node '$node-id' has no 'inputs'"
		unless %!data{$node-id}<inputs>:exists;
	%!data{$node-id}<inputs>{$field} = $value;
}

method set-by-title(Str:D $title, Str:D $field, $value --> Nil) {
	for %!data.kv -> Str $id, %node {
		if (%node<_meta><title> // '') eq $title {
			self.set($id, $field, $value);
			return;
		}
	}
	die "ComfyUI::API::Workflow: no node with title '$title'";
}

method find-nodes-by-class(Str:D $class-type --> List) {
	%!data.keys.grep(-> Str $id {
		(%!data{$id}<class_type> // '') eq $class-type
	}).sort.list;
}

method render(%vars --> ComfyUI::API::Workflow:D) {
	my %rendered = self!render-value(%!data, %vars);
	ComfyUI::API::Workflow.new(:data(%rendered));
}

method to-json(--> Str:D) {
	to-json(%!data, :sorted-keys);
}

method to-hash(--> Hash) {
	%!data.Hash;
}

method !render-value($value, %vars) {
	given $value {
		when Hash {
			my %result;
			for $value.kv -> $k, $v {
				%result{$k} = self!render-value($v, %vars);
			}
			%result;
		}
		when Array {
			$value.map({ self!render-value($_, %vars) }).Array;
		}
		when Str {
			$value.subst(/ '{{' (<-[}]>+) '}}' /, -> $/ {
				my Str:D $key = ~$0;
				die "ComfyUI::API::Workflow: missing variable '$key' in render"
					unless %vars{$key}:exists;
				~%vars{$key};
			}, :g);
		}
		default { $value }
	}
}
