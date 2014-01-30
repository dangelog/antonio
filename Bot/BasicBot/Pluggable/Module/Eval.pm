package Bot::BasicBot::Pluggable::Module::Eval;

use strict;
use warnings;

use Data::Dumper;

use Bot::BasicBot::Pluggable::Module; 
use base qw(Bot::BasicBot::Pluggable::Module);

sub init { }

sub said { 
	my ($self, $mess, $pri) = @_;

	my $body = $mess->{body}; 

	return unless $pri == 2;
	return unless $body =~ /^\s*eval\s+(.+)\s*$/;
	my $what = $1;

	my $output = eval $what;
	if ($@) {
		$@ =~ s#/.+: (.*) at /.+\n#$1#;
		return "EVAL ERROR: $@";
	}

	return "EVAL: $output";
}

sub help {
	return "Commands: 'eval <text>'";
}

1;

