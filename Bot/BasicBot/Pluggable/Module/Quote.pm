package Bot::BasicBot::Pluggable::Module::Quote;
use warnings;
use strict;
use base qw(Bot::BasicBot::Pluggable::Module);

# TODO
# annunciare sul canale relativo l'inserimento di un quote multilinea
#  PROBLEMA: Join non fa estrarre i canali correnti
#  SOLUZIONE: usare Join2
my %multiline_quotes;

sub said {
    my ($self, $mess, $pri) = @_;
    my $body = $mess->{body};
    my $who = $mess->{who};
    my $channel = $mess->{channel};
    
    return unless ($pri == 2);
    return unless $mess->{address};

    my ($command, $param) = split(/\s+/, $body, 2);
    $command = lc($command);
    
    # aggiunta quote multilinea
    if ($channel eq "msg" and exists $multiline_quotes{$who}) {
        if ($body eq ".") {
            my $quote = $multiline_quotes{$who};
            delete $multiline_quotes{$who};
            return $self->addquote_multiline($who, $quote);
        } elsif ($body eq "!") {
            delete $multiline_quotes{$who};
            return "Ok, multiline quote aborted."
        } else {
            $multiline_quotes{$who} .= "\n" . $body;
        }
    } elsif ($command eq "multiquote" and $channel eq "msg") {
        $multiline_quotes{$who} = "";
        return "Ok, type your quote and end with a single period, or ! to cancel."

    # richiesta di quote
    } elsif ($command eq "quote" or $command eq "lsquote" or $command eq "whoquote") {
        return $self->quote($command, $param);

    # aggiunta quote normale
    } elsif ($command eq "addquote" and $param and $channel ne "msg") {
        if ($mess->{channel} eq "msg") {
            return "Sorry, quotes cannot be added here. Somethin to hide?";
        } else {
            return "ok, quote #" . $self->addquote($who, $param, 0, 0);
        }

    # cancellazione quote
    } elsif ($command eq "delquote" ) {    
        if ($channel eq "msg") {
            return "Sorry, quotes cannot be deleted here. Somethin to hide?";
        } else {
            if (!$self->bot->module("Auth")->authed($who)) {
                return "You need to authenticate. Fuck you and fuck your fucking mother."
            } elsif ($param =~ m/^\#(\d+)$/) {
                return $self->delquote($1);
            } else {
                return "Syntax error"
            }
        }
    }     
    return undef;
}

sub delquote {
    my ($self, $quoteno) = @_;
    
    my @quotes = @{ $self->get("quote_db") || [] };
    my @deleted = grep($_->{id} == $quoteno, @quotes);
    
    if (@deleted) {
        @quotes = grep($_->{id} != $quoteno, @quotes);
        $self->set("quote_db", \@quotes);

        return "quote $quoteno deleted.";
    } else {
        return "no such quote."
    }
}

sub quote {
    my ($self, $command, $param) = @_;
    my @quotes = @{ $self->get("quote_db") || [] };

    if (defined $param and $param ne "") {
        if ($param =~ m/^\#(\d+)$/) {
            @quotes = grep($_->{id} == $1, @quotes);
        } else {
            eval {
                @quotes = grep($_->{body} =~ m/$param/i, @quotes);
            };
            return undef if $@;
        }
    }
    
    if ($command eq "quote") {
        if (@quotes) {
            my $quote = $quotes[ rand(@quotes) ];
            if ($quote->{multiline}) {
                return "#" . $quote->{id} . ": multiline quote: " .
                $self->bot->module("Tumblr")->blog_url . "/post/" . $quote->{postid};
            } else {
                return "#" . $quote->{id} . ": " . $quote->{body};
            }
        } else {
            return "no such quote.";
        }
    } elsif ($command eq "lsquote") {
        my $reply = @quotes . " matching quote";

        $reply .= "s" if (@quotes != 1);
        
        if (@quotes) {
            my @quotelist = map ($_->{id}, @quotes);
            fisher_yates_shuffle(\@quotelist);
            splice(@quotelist, 20) if (@quotelist > 20);
            @quotelist = sort {$a <=> $b} @quotelist;
            $reply .= ": " . join(" ", @quotelist);;
        }

        return $reply;
    } elsif ($command eq "whoquote") {
        if (@quotes) {
            my $quote = $quotes[ rand(@quotes) ];
            return "quote #" . $quote->{id} .
                ($quote->{multiline} ? " (multiline)" : "" ) .
                " was added by " . $quote->{who} .
                " on " . localtime($quote->{timestamp});
        } else {
            return "no such quote.";
        }
    }
    
    return undef;
}

sub addquote {
    my ($self, $who, $quote, $multiline, $postid) = @_;
    my $quotenext = $self->get("quote_next") || 0;
    my @quotes = @{ $self->get("quote_db") || [] };
    
    my $row = {
        id => $quotenext,
        who => $who,
        timestamp => time,
        body => $quote,
        multiline => $multiline,
        postid => $postid
    };
    push(@quotes, $row);

    $quotenext++;
    $self->set("quote_next" => $quotenext);
    $self->set("quote_db" => \@quotes);

    return ($quotenext - 1);
}

sub addquote_multiline {
    my ($self, $who, $quote) = @_;

    return "Error, empty quote" if ($quote eq "");

    $quote = $self->bot->module("Tumblr")->htmlize_text($quote);

    my $response = $self->bot->module("Tumblr")->post_text($quote, []);
    
    if ($response) {
        my $quoteid = $self->addquote($who, $quote, 1, $response);
        my @channels = $self->bot->channels;
        foreach my $chan (@channels) {
            $self->tell($chan, "$who just added a multiline quote, id #$quoteid, " .
                $self->bot->module("Tumblr")->blog_url . "/post/" . $response);
        }
        return "Ok, quote #" . $quoteid;
    } else {
        return "Error while posting quote on blog";
    }
}


sub help {
    return "see http://wiki.linux.it/IRC";
}

sub fisher_yates_shuffle {
    my $array = shift;
    my $i;
    for ($i = @$array; --$i; ) {
        my $j = int rand ($i + 1);
        next if $i == $j;
        @$array[$i,$j] = @$array[$j,$i];
    }
}

1;

