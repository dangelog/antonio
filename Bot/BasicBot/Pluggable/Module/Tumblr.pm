package Bot::BasicBot::Pluggable::Module::Tumblr;

use warnings;
use strict;
use base qw(Bot::BasicBot::Pluggable::Module);

use Config::Any;

use Crypt::SSLeay;
require LWP::UserAgent;
require LWP::Authen::OAuth;
require HTTP::Request;

use HTTP::Date qw(time2str);
use JSON;
use URI;
use Regexp::Common qw(URI);
use HTML::Entities qw(encode_entities decode_entities);
use Regexp::Common::URI::RFC2396 qw /$path_segments/;

use Data::Dumper;

my $conf_file = "tumblr.conf.json";

# TODO
# rendere le whitelist / blacklist dei nick modificabili a runtime (?)

# merdate di OAuth
my $tumblr_request_token_url = 'http://www.tumblr.com/oauth/request_token';
my $tumblr_authorize_url = 'http://www.tumblr.com/oauth/authorize';
my $tumblr_access_token_url = 'http://www.tumblr.com/oauth/access_token';

my $tumblr_consumer_key;
my $tumblr_consumer_secret;

my $tumblr_oauth_token;
my $tumblr_oauth_token_secret;

my $twitter_consumer_key;
my $twitter_consumer_secret;

my $twitter_oauth_token;
my $twitter_oauth_token_secret;

# dominio del tumblr e varie API urls (costruite dal dominio)
my $tumblr_domain;

my $tumblr_post_url;
my $tumblr_reblog_url;
my $tumblr_url;

# chi e` il fortunello impostato con [anon]
my $boss;

# domini da NON memorizzare di default
my @common_domains;

# nuff said
my @nick_blacklist;     
my @nick_whitelist;

# il match sul nick e` decisamente migliorabile
# probabilmente use constant (ma anche chissene)
my $nick_regexp = qr/[\w\[\]\`\\\-]+/i;
my $url_regexp = qr|$RE{URI}{HTTP}{-scheme => qr/https?/}(?:#$path_segments)?|i;
my $agent;
my $tumblr_agent;
my $twitter_agent;

sub load_config_file {
    my $cfg = Config::Any->load_files({ files => [ $conf_file ], use_ext => 1, flatten_to_hash => 1 }) or die "Can't load configuration file $conf_file";
    die "Configuration file empty" unless exists $cfg->{$conf_file};
    my $tumblr_cfg = $cfg->{$conf_file};

    # nome della variabile nel file di config => ref alla variable locale da inizializzare
    my %config_vars = (
        tumblr_domain => \$tumblr_domain,
        tumblr_consumer_key => \$tumblr_consumer_key,
        tumblr_consumer_secret => \$tumblr_consumer_secret,
        tumblr_oauth_token => \$tumblr_oauth_token,
        tumblr_oauth_token_secret => \$tumblr_oauth_token_secret,

        twitter_consumer_key => \$twitter_consumer_key,
        twitter_consumer_secret => \$twitter_consumer_secret,
        twitter_oauth_token => \$twitter_oauth_token,
        twitter_oauth_token_secret => \$twitter_oauth_token_secret,

        boss => \$boss,
        common_domains => \@common_domains,

        nick_blacklist => \@nick_blacklist,
        nick_whitelist => \@nick_whitelist,
    );

    # controlla se la corrispondente variabile e` stata effettivamente impostata dal file di configurazione
    my %config_var_not_set;
    # popola con le stesse chiavi (e un qualsiasi valore)
    @config_var_not_set{ keys %config_vars } = (undef) x scalar(keys %config_vars);

    while (my ($conf_key, $conf_variable) = each %config_vars) {
        die "Configuration file does not set $conf_key" unless exists $tumblr_cfg->{$conf_key};

        my $value = $tumblr_cfg->{$conf_key};
        my $type = ref($conf_variable);

        if ($type eq "SCALAR") {
            $$conf_variable = $value;
        } elsif ($type eq "ARRAY") {
            @$conf_variable = @$value;
        } elsif ($type eq "HASH") {
            %$conf_variable = %$value;
        } else {
            die "Internal error: invalid ref type for the config variable set by $conf_key";
        }

        delete $config_var_not_set{$conf_key};
    }

    die "These configuration variables were not set in the config file: " . join(", ", keys %config_var_not_set) if (%config_var_not_set);

    # ultime inizializzazioni...

    $tumblr_post_url = "http://api.tumblr.com/v2/blog/$tumblr_domain/post";
    $tumblr_reblog_url = "http://api.tumblr.com/v2/blog/$tumblr_domain/post/reblog";
    $tumblr_url = "http://$tumblr_domain";

    push @common_domains, $tumblr_domain;
}

sub init {
    load_config_file();

    $agent = LWP::UserAgent->new;
    $agent->agent('Antonio/3.14');

    $tumblr_agent = LWP::Authen::OAuth->new(
        oauth_consumer_key => $tumblr_consumer_key,
        oauth_consumer_secret => $tumblr_consumer_secret,
        oauth_token => $tumblr_oauth_token,
        oauth_token_secret => $tumblr_oauth_token_secret
    );
    $tumblr_agent->agent('Antonio/3.14');

    $twitter_agent = LWP::Authen::OAuth->new(
        oauth_consumer_key => $twitter_consumer_key,
        oauth_consumer_secret => $twitter_consumer_secret,
        oauth_token => $twitter_oauth_token,
        oauth_token_secret => $twitter_oauth_token_secret
    );

    $twitter_agent->agent('Antonio/3.14');
}


sub said {
    my ($self, $mess, $pri) = @_;

    return unless $pri == 3;
    
    my $who = $mess->{who};
    my $body = $mess->{body};
    my $channel = $mess->{channel};

    return if $channel eq 'msg';

    # OTR => niente
    return if $body =~ /(^|\W)\[OTR\](\W|$)/i;

    # capo di andreaf
    my $displayed_who = $who;
    
    # tutti possono usare [anon], ma solo i whitelist [anon=foo].
    # se qualcuno non in whitelist ci prova viene punito (aka non funziona)
    if ($body =~ s/(?:^|\W)\[anon(?:=($nick_regexp))?\](?:\W|$)//ig) {
        if (defined $1) {
            foreach my $nick (@nick_whitelist) {
                if (lc $who eq lc $nick) {
                    $displayed_who = $1;
                    last;
                }
            }
        } else {
            $displayed_who = $boss;
        }
    }    
    
    my $should_post = 0;
    
    # jolly tag
    $should_post = 1 if ($body =~ s/(?:^|\W)\[8=D\](?:\W|$)//);

    # estraggo i tag rimanenti. minimo tre lettere per un tag, e una di queste \w
    my $clean_body = $body;
    $clean_body =~ s|$url_regexp||ig;
    # FIXME metti la regexp in uno stesso posto
    # FIXME togliere il grep
    my @tags = ($clean_body =~ m|\[(\S[^\]]+\S)\]|ig);
    $clean_body =~ s|\[(\S[^\]]+\S)\]||ig;
    @tags = map { lc } (grep { /\w/i } @tags); 

    # controllo whitelist/blacklist/graylist.
    # la graylist si passa solo con un tag,
    # in alternativa [8=D] vale come jolly
    
    foreach my $nick (@nick_whitelist) {
        $should_post = 1 if lc $who eq lc $nick;
    }
    
    if (@tags) {
        $should_post = 1;
    }
    
    foreach my $nick (@nick_blacklist) {
        $should_post = 0 if lc $who eq lc $nick;
    }

#    print STDERR "messaggio da |$who|, body |$body|, postabile |$should_post|, da postare come |$displayed_who|, tags |" . join(",", @tags). "|\n";
#    return;
    
    $who = $displayed_who;
  
    # tra i tag ci finisce pure l'autore del post
    push @tags, "by:$who";

    my %saw = map { $_ => 1 } @tags;
    @tags = keys %saw;
    

    # fix per twitter. ask Md
    $body =~ s|(https?://\w{0,3}\.?twitter\.com/)#!/|$1|ig;

    # estrazione URL 
    my (@url_list) = $body =~ m|($url_regexp)|ig;
    return unless @url_list;

    # filtra via le url "common"
    unless ($mess->{address}) {
        foreach my $domain (@common_domains) {
            @url_list = grep {
                $_ =~ m|$RE{URI}{HTTP}{-keep}{-scheme => qr/https?/}|i,
                $3 !~ m|$domain$|i
            } @url_list;
        }
    }
    return unless @url_list;


    # gestione OLD.
    # non dico OLD se nella frase c'e` [PND] oppure e` rivolta a qualcuno.
    my %old_urls; # url => informazioni per quell'url
    foreach my $url (@url_list) {
        my $url_data = $self->get("tumblr_urlcache_$url");
        $old_urls{$url} = $url_data if $url_data; 
    }
    
    if ($body !~ /(^|\W)\[PND\](\W|$)/i and $body !~ /^$nick_regexp [:,]\s/x) {
       if (%old_urls) {
            my %url_index_hash;
            @url_index_hash{@url_list} = (0..$#url_list);
            my @yells;
            my $oldcount = 0;
            foreach my $url (keys %old_urls) {
                my $url_data = $old_urls{$url};
                
                push @yells, "url #" . $url_index_hash{$url} 
                    . " was posted by " . $url_data->{who}
                    . " on " . localtime($url_data->{timestamp});
                
                my $count = $url_data->{count}++;
                
                my $howold = (time - $url_data->{timestamp}) / 86400.0;
                
                if ($howold >= 1) {
                    $howold = int( log($howold) / log(4) ) + 1; 
                } else {
                    $howold = 0;
                }

                $oldcount += ($count + $howold);
                
                $self->set("tumblr_urlcache_$url", $url_data);
            }
            
            $oldcount = 1 if ($oldcount < 1);
            $oldcount = 10 if ($oldcount > 10);

            my $old_yell = "$who: " . ("O" x $oldcount) . "LD! " . join(', ', @yells);

            $self->tell($channel, $old_yell);
        }
    }

    # ritorno se il mittente non poteva mandare -- lo faccio qui in modo da far
    # scattare i relativi old
    return unless $should_post;

    # si processano solo le url NON vecchie
    @url_list = grep { not exists $old_urls{$_} } @url_list;
    return unless @url_list;

    # un ultimo giro di inizializzazioni...
    my $text = $self->htmlize_text('<' . $who . '> ' . $body);

    %saw = map { $_ => 1 } @url_list;
    my @unique = keys %saw;

    # aggiunta vera e propria
    # $posted mi ricorda se l'ho gia` aggiunto come video/immagine/retumblr/ecc.
    my $posted = 0;

    foreach my $url (@unique) {
        my $ok = 0;

        if ($body !~ m/(^|\W)\[nsfw\](\W|$)/i) {
            # twitter
            if ($url =~ m|^https?://(?:www\.)?twitter.com/.*/status(?:es)?/(\d+)|i) {
                $ok = $self->post_twitter($url, $text, $1, \@tags);
                $posted = 1 if $ok;
            } else {
                # non twitter. HEAD per vedere che diavolo e`
                my $head = $self->do_head($url);
                next unless $head;

                # post su un tumblr => reblog
                if (defined $head->header("X-Tumblr-User")) {
                    $url =~ m|$RE{URI}{HTTP}{-keep}|i;
                    my $path = $7;
                    if ($path =~ m|^post/\d+|i) { 
                        $ok = $self->reblog_post($url, ($clean_body =~ m/^\s*$/) ? undef : $text, \@tags);
                        $posted = 1 if $ok;
                    }            
                } 
                # immagine
                elsif ( 
                       (defined $head->header("Content-Type")
                       && $head->header("Content-Type") =~ m|^image/|)

                       || $url =~ m/\.(gifa?|jpe?g|png)$/i
                       ) { 
                    $ok = $self->post_image($url, $text, \@tags);
                    $posted = 1 if $ok;
                } 
                # video
                elsif ( 
                       $url =~ m|^https?://\w{0,3}\.?youtube\.com/watch|i
                       || $url =~ m|^http://\w{0,3}\.?vimeo\.com/\d+|i
                       ) { 
                    $ok = $self->post_video($url, $text, \@tags);
                    $posted = 1 if $ok;
                }
            }

        } else {
            # nsfw => posta solo come plaintext

            $ok = $self->post_text($text, \@tags);
            $posted = 1 if $ok;
        }

        if ($ok) {
            # metti in cache solo se abbiamo postato

            $self->set("tumblr_urlcache_$url", { who => $who , timestamp => time , count => 1});
        }
    }

    # se non ho postato (o il posting col formato nativo e` fallito),
    # posta ora in plaintext
    unless ($posted) {
        my $ok = $self->post_text($text, \@tags);

        # debate: metti in cache se questo catch-all ha successo, o no? io dico no (cosi` puoi tentare piu` tardi)

#        if ($ok) {
#            foreach my $url(@unique) {
#                $self->set("tumblr_urlcache_$url", { who => $who , timestamp => time , count => 1});
#            }
#        }
    }

    return undef;
}

sub do_head {
    my ($self, $url) = @_;
    return undef unless $url;

    my $response = $agent->head($url);
    
    if ($response->is_success) {
        return $response;
    } else {
        return undef;
    }        
}


sub htmlize_text {
    my ($self, $text) = @_;

    encode_entities($text);

    $text =~ s|($RE{URI}{HTTP}{-scheme => qr/https?/}(?:#$path_segments)?)|<a href="$1">$1</a>|ig;
    return $text;
}

sub post_text {
    my ($self, $text, $tagsref) = @_;
    return 0 unless $text;

    my @content = (
        type => 'regular',
        body => $text,
    );

    return $self->do_post_tumblr(\@content, $tagsref);
}

sub post_image {
    my ($self, $imageurl, $text, $tagsref) = @_;
    return 0 unless $imageurl;

    my @content = (
        type => 'photo',
        source => $imageurl,
    );
    push(@content, 'caption' => $text) if $text;

    return $self->do_post_tumblr(\@content, $tagsref);
}

sub post_video {
    my ($self, $videourl, $text, $tagsref) = @_;
    return 0 unless $videourl;

    my @content = (
        type => 'video',
        embed => $videourl,
    );
    push(@content, 'caption' => $text) if $text;

    return $self->do_post_tumblr(\@content, $tagsref);
}

sub post_quote {
    my ($self, $quote, $text, $tagsref) = @_;
    return 0 unless $quote;
    
    my @content = (
        type => 'quote',
        quote => $quote,
    );
    
    push(@content, 'source' => $text) if $text;
    
    return $self->do_post_tumblr(\@content, $tagsref);
}

sub post_twitter {
    my ($self, $url, $text, $id, $tagsref) = @_;
    return 0 unless $id;

    my $response = $twitter_agent->get("https://api.twitter.com/1.1/statuses/show/$id.json?trim_user=1");
    return 0 unless $response->code == 200;
   
    my $json_response = decode_json($response->content);
    my $tweet = $json_response->{text};

    return 0 unless defined $tweet;
    $tweet = htmlize_text($self, $tweet);
    
    return $self->post_quote($tweet, $text, $tagsref);
}

sub do_post_tumblr {
    my ($self, $content, $tagsref) = @_;
    return 0 unless $content;

    my @tags = @$tagsref;
    push(@$content, "tags" => join(",", map { "\"$_\"" } @tags)) if @tags;

    my $response = $tumblr_agent->post(
        $tumblr_post_url, 
        Content => $content
    );

    print STDERR "Tumblr: returned |", $response->code, "| for content <", join("><", @$content), ">\n";

    if ($response->code == 201) {
        my $response = decode_json($response->content);
        my $post_id = $response->{response}->{id};
        return $post_id;
    } else {
        return 0;
    }
}

sub reblog_post {
    my ($self, $url, $text, $tagsref) = @_;
    return 0 unless $url;

    # 0 costruisco l'url per recuperare la reblog key
    $url =~ m/$RE{URI}{HTTP}{-keep}/i;
    my $blog = $3; # dominio
    my $path = $7;

    $path =~ m|^post/(\d+)|i;
    my $postid = $1;

    return 0 unless (defined $blog && defined $postid);

    my $read_api_url = URI->new("http://api.tumblr.com/v2/blog/$blog/posts");
    $read_api_url->query_form(
        api_key => $tumblr_consumer_key,
        id => $postid
    );

    # 1 recupera la fottuta reblog key
    my $response = $tumblr_agent->get($read_api_url);
    return 0 unless $response->code == 200;

    my $json_response = decode_json($response->content);
    my $reblogkey = $json_response->{response}->{posts}->[0]->{reblog_key};    

    print STDERR "REBLOG KEY $reblogkey \n";

    return 0 unless defined $reblogkey;

    # 2 reblog vero e proprio
    my @content = (
        'id'         => $postid,
        'reblog_key' => $reblogkey,
    );
    push(@content, 'comment' => $text) if $text;

    my @tags = @$tagsref;
    push(@content, "tags" => join(",", map { "\"$_\"" } @tags)) if @tags;

    $response = $tumblr_agent->post(
        $tumblr_reblog_url,
        Content => \@content
    );

    if ($response->code == 201) {
        return $response->content;
    } else {
        return 0;
    }
}

sub blog_url {
    return $tumblr_url;
}

sub help {
    return "see your links on $tumblr_url !";
}

1;
