package Bot::BasicBot::Pluggable::Module::Join2;
use warnings;
use strict;

use base qw(Bot::BasicBot::Pluggable::Module::Join);

# e` Join, ma mi rende la lista dei canali (usato per annunciare da Quote)

sub channels {
	my ($self) = @_;
	return split(/\s+/, $self->get("channels"));
}

sub said {
	my ($self, $mess, $pri) = @_;
	my $who = $mess->{who};

	return unless $mess->{address} and $pri == 2;
	return unless $self->bot->module("Auth")->authed($who);
	return $self->SUPER::said($mess, $pri);
}

1;
