package Bot::BasicBot::Pluggable::Module::LART;

use strict;
use warnings;

use Bot::BasicBot::Pluggable::Module; 
use base qw(Bot::BasicBot::Pluggable::Module);

# the LARTS database
my @larts;

sub init {
	my $file = 'antonio.larts'; # XXX

	if (not open(DATA, $file)) {
		warn "cannot open $file"; # XXX
		return;
	}

	undef @larts;
	foreach (<DATA>) {
		chomp;
		next if /^\s*$/ or /^#/;
		push(@larts, $_);
	}

	close DATA;	
}

sub said { 
	my ($self, $mess, $pri) = @_;

	my $body = $mess->{body}; 
	my $who  = $mess->{who};
	my $channel = $mess->{channel};

	return unless $pri == 2;
	return unless $body =~ /^\s*lart (\S+)(?:\s+(#\S+))?\s*$/;
	my ($person, $outchannel) = ($1, $2);

	return "Sorry, I do not know any LART..." if not @larts;

	my $lart = $larts[rand scalar @larts];
	$lart =~ s/WHO/$person/g;

	if ($channel eq 'msg') { # emoted request
		return "I don't know which channel $person is in!" if not $outchannel;
		$channel = $outchannel;
		$lart .= " (courtesy of $who)";
	}

	$self->bot->emote(who => $who, channel => $channel, body => $lart);
	return undef;
}

sub help {
	return "Commands: 'lart <who> [<#channel>]'";
}

1;

