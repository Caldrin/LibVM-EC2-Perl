package VM::S3::Http_helper;

use strict;
use Digest::SHA 'sha256_hex','hmac_sha256','hmac_sha256_hex';
use AWS::Signature4;

# utility class for http requests; forms a virtual base class for VM::S3

# Shame on AnyEvent::HTTP! Doesn't correctly support 100-continue, which we need!
use constant MAX_RECURSE => 5;
use constant CRLF        => "\015\012";
use constant CRLF2       => CRLF.CRLF;
#use constant CHUNK_SIZE  => 65536; # 64K
use constant CHUNK_SIZE  => 8192;   # 8K

my %_cached_handles;
sub submit_http_request {
    my $self    = shift;
    my ($req,$cv,$state) = @_;

    # force the request into shape
    my $request = $req->clone();
    $request->header(Host   => $request->uri->host) unless $request->header('Host');
 
    # state variables for recursion handling
    $cv               ||= $self->condvar;
    $state            ||= {};
    $state->{recurse}   = MAX_RECURSE unless exists $state->{recurse};
    if ($state->{recurse} <= 0) {
	$self->error(VM::EC2::Error->new({Message=>'too many redirects',Code=>500},$self));
	$cv->send();
	return $cv;
    }
    $state->{request}  ||= $request;
    $state->{response} ||= undef;

    warn $request->as_string;

    my $uri      = $request->uri;
    my $method   = $request->method;
    my $headers  = $request->headers->as_string;
    my $host     = $uri->host;
    my $scheme   = $uri->scheme;
    my $resource = $uri->path;
    my $port     = $uri->port;
    my $tls      = $scheme eq 'https';

    # BUG: ignore http proxy environment variable
    my $handle = $self->_get_http_handle($host,$port,$tls,$cv);
    
    # do the writes
    $handle->push_write("PUT $resource HTTP/1.1".CRLF);
    $handle->push_write($headers.CRLF);  # headers already has a crlf, so we get two here

    $self->_push_body_writes($cv,$state,$handle) unless $request->header('Expect') eq '100-continue';

    # read the status line & headers
    $handle->push_read (line => CRLF2,sub {$self->_handle_http_headers($cv,$state,@_)});

    return $cv;
}

sub _get_http_handle {
    my $self = shift;
    my ($host,$port,$tls,$cv) = @_;

    if ($_cached_handles{$host,$port}) {
	return $_cached_handles{$host,$port} unless $_cached_handles{$host,$port}->destroyed;
    }

    my $handle; 
    $handle = AnyEvent::Handle->new(connect => [$host,$port],
				    $tls ? (tls=>'connect') : (),

				    on_eof => sub {$handle->destroy()},

				    on_error => sub {
					my ($handle,$fatal,$message) = @_;
					$self->_handle_http_error($cv,$handle,$message,599);
				    }
	);

    return $_cached_handles{$host,$port} = $handle;
}

sub _handle_http_error {
    my $self = shift;
    my ($cv,$handle,$message,$code) = @_;
    $self->error(VM::EC2::Error->new({Message=>$message,Code=>$code},$self));    
    $handle->destroy();
    $cv->send();
    1;
}

sub _handle_http_headers {
    my $self = shift;
    my ($cv,$state,$handle,$str) = @_;
    my $response = HTTP::Response->parse($str);

    warn $response->as_string;

    $state->{response} = $response;
    # handle continue
    if ($response->code == 100) {
	$self->_push_body_writes($cv,$state,$handle);
	$handle->push_read (line => CRLF2,sub {$self->_handle_http_headers($cv,$state,@_)});	
    } 

    # handle counted content
    elsif (my $len = $response->header('Content-Length')) {
	$state->{length} = $len;
	$handle->on_read(sub {$self->_handle_http_body($cv,$state,@_)} );
    } 

    # handle chunked content
    elsif ($response->header('Transfer-Encoding') =~ /\bchunked\b/) {
	$handle->push_read(line=>CRLF,sub {$self->_handle_http_chunk_header($cv,$state,@_)});
    }

    # no content, just finish up
    else {
	$self->_handle_http_finish($cv,$state);
    }
}

sub _handle_http_body {
    my $self = shift;
    my ($cv,$state,$handle) = @_;
    my $headers = $state->{response} or $self->_handle_http_error($cv,$handle,"garbled http body",500) && return;
    my $data    = $handle->rbuf;
    $state->{body} .= $data;
    $handle->rbuf = '';
    $state->{length} -= length $data;
    $self->_handle_http_finish($cv,$state) if $state->{length} <= 0;
}


sub _handle_http_chunk_header {
    my $self = shift;
    my ($cv,$state,$handle,$str) = @_;
    $str =~ /^([0-9a-fA-F]+)/  or $self->_handle_http_error($cv,$handle,"garbled http chunk",500) && return;
    my $chunk_len = hex $1;
    if ($chunk_len > 0) {
	$state->{length} = $chunk_len + 2;  # extra CRLF terminates chunk
	$handle->push_read(chunk=>$state->{length}, sub {$self->_handle_http_chunk($cv,$state,@_)});
    } else {
	$handle->push_read(line=>CRLF, sub {$self->_handle_http_finish($cv,$state,$handle)});
    }
}

sub _handle_http_chunk {
    my $self = shift;
    my ($cv,$state,$handle,$str) = @_;
    $state->{length} -= length $str;

    local $/ = CRLF;
    chomp($str);
    $state->{body}   .= $str;

    if ($state->{length} > 0) { # more to fetch
	$handle->push_read(chunk=>$state->{length}, sub {$self->_handle_http_chunk($cv,$state,@_)});
    } else { # next chunk
	$handle->push_read(line=>CRLF,sub {$self->_handle_http_chunk_header($cv,$state,@_)});
    }

}

sub _handle_http_finish {
    my $self = shift;
    my ($cv,$state,$handle) = @_;
    my $response = $state->{response} 
                   or $self->_handle_http_error($cv,$handle,"no header seen in response",500) && return;
    if ($response->is_redirect) {
	my $location = $response->header('Location');
	my $uri = URI->new($location);
	$state->{request}->uri($uri);
	$state->{request}->header(Host => $uri->host);
	$state->{recurse}--;
	$self->submit_http_request($state->{request},$cv,$state);
    } elsif ($response->is_error) {
	my $error = VM::EC2::Dispatch->create_error_object($state->{body},$self,'put object');
	$cv->error($error);
	$cv->send();
    }
    else {
	$self->error(undef);
	$response->content($state->{body});
	$cv->send($response);
    }
    $handle->destroy() if $response->header('Connection') eq 'close';
}

sub _push_body_writes {
    my $self = shift;
    my ($cv,$state,$handle) = @_;
    my $request     = $state->{request} or return;
    my $content     = $request->content;

    unless ($self->_is_fh($content)) {
	$handle->push_write($content);
	return;
    }

    # we get here if we are uploading from a filehandle
    # using chunked transfer-encoding
    my $authorization                = $request->header('Authorization');
    $state->{signature}{timedate}    = $request->header('X-Amz-Date');
    ($state->{signature}{previous})  = $authorization =~ /Signature=([0-9a-f]+)/;
    ($state->{signature}{scope})     = $authorization =~ m!Credential=[^/]+/([^,]+),!;
    my ($date,$region,$service)      = split '/',$state->{signature}{scope};
    $state->{signature}{signing_key} = AWS::Signature4->signing_key($self->secret,$service,$region,$date);

    $handle->on_drain(
	sub { 
	    my $handle = shift;
	    my $buffer = '';
	    my $bytes_left = CHUNK_SIZE;
	    while ($bytes_left) {
		warn "trying to read $bytes_left bytes";
		my $bytes  = sysread($content,$buffer,$bytes_left,length $buffer);
		warn "got $bytes bytes";
		if (length $buffer >= CHUNK_SIZE) {# got everything we need
		    $self->_write_chunk($cv,$state,$handle,$buffer);
		} elsif ($bytes==0) { # eof!
		    $self->_write_chunk($cv,$state,$handle,$buffer);
		    $self->_write_chunk($cv,$state,$handle,'');  # last chunk
		    last;
		}
		$bytes_left -= $bytes;
	    }
	});
}

sub _write_chunk {
    my $self = shift;
    my ($cv,$state,$handle,$data) = @_;
    warn "write chunk length=",length $data;
    # first compute the chunk signature
    my $hash = sha256_hex($data);
    my $string_to_sign = join("\n",
			      'AWS4-HMAC-SHA256-PAYLOAD',
			      $state->{signature}{timedate},
			      $state->{signature}{scope},
			      $state->{signature}{previous},
			      sha256_hex(''),
			      $hash);
    warn "chunk-string-to-sign=\n$string_to_sign.";
    my $signature = hmac_sha256_hex($string_to_sign,$state->{signature}{signing_key});

    my $len            = sprintf('%x',length $data);
    my $chunk_metadata = "$len;chunk-signature=$signature"; 
    warn "chunk-metadata = .$chunk_metadata.";
    my $chunk          = join (CRLF,$chunk_metadata,$data).CRLF;
    $handle->push_write($chunk);
    $state->{signature}{previous} = $signature;

    if (length $data == 0) {
	warn "last chunk";
	delete $state->{signature};
	$handle->on_drain(undef);
    }

}

sub _is_fh {
    my $self = shift;
    my $obj  = shift;
    return unless ref $obj;
    return unless ref($obj) eq 'GLOB';
    my @s = stat($obj);
    defined $s[7] or return;
    return $s[7];
}

1;