unit class ComfyUI::API::Result;

has Str:D $.prompt-id is required;
has %!data;

submethod BUILD(:$!prompt-id, :%!data) {}

method new(Str:D :$prompt-id, :%data --> ComfyUI::API::Result:D) {
	self.bless(:$prompt-id, :%data);
}

method images(--> List) {
	my @images;
	for %!data<outputs>.values -> %node-output {
		if %node-output<images>:exists {
			for @(%node-output<images>) -> %img {
				@images.push(%img);
			}
		}
	}
	@images.list;
}

method image-filenames(--> List) {
	self.images.map({ $_<filename> }).list;
}

method output-for-node(Str:D $node-id --> Hash) {
	%!data<outputs>{$node-id} // %();
}

method raw(--> Hash) {
	%!data.Hash;
}
