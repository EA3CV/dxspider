#
# load list of bad dx calls
#
# Copyright (c) 2026 - Dirk Koopman G1TLH
#
#

use strict;
use warnings;

my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->remotecmd;
return (1, $self->msg('e5')) if $self->priv < 9;

my $name = 'baddx';
my $target = $DXProt::baddx;
return (1, "Operation failed")
    unless $target && ref($target) eq 'DXHash' && $target->{name} eq $name;

my ($merged, $sources, $error);
my $reading_path = "(enumerating sources)";
{
    local $@;
    eval {
        die "local_data not initialized" unless
            defined($main::local_data) && length($main::local_data);
        my @paths = DXHash::_list_files($name);
        my %values;
        for my $path (@paths) {
            $reading_path = $path;
            my $obj = DXHash::_list_read($path);
            die "invalid list name in $path" if
                exists($obj->{name}) && $obj->{name} ne $name;
            for my $call (keys %$obj) {
                next if $call eq 'name';
                die "invalid entry in $path" unless
                    defined($call) && length($call) &&
                    defined($obj->{$call}) &&
                    $obj->{$call} =~ /\A[0-9]+\z/;
                $values{$call} = $obj->{$call};
            }
        }
        $merged = \%values;
        $sources = scalar @paths;
        1;
    } or $error = $@ || 'unknown read error';
}
if ($error) {
    # Perl eval diagnostics can contain source fragments, newlines and
    # volatile "(eval N)" identifiers. Never expose them in operator logs.
    my $reason = 'read_error';
    my $detail = 'unable to read source';
    if ($error =~ /(?:syntax error|compilation errors|invalid \S+|invalid list name|invalid entry|does not return|not a hash|bad format)/i) {
        $reason = 'invalid_format';
        $detail = 'invalid native DXHash data';
    } elsif ($error =~ /local_data not initialized/) {
        $reason = 'configuration_error';
        $detail = 'local_data not initialized';
    }
    my $message = "load/$name: ERROR file=$reading_path reason=$reason action=reload_aborted memory=unchanged";
    DXDebug::dbg($message);
    return (1, "Operation failed");
}

# Build the complete replacement in isolation, including DXHash::add()
# basecall fallback, before touching the live object.
my $fresh = bless { name => $name }, 'DXHash';
for my $call (sort keys %$merged) {
    $fresh->add($call, $merged->{$call});
}
my (%old, %new);
%old = map { $_ => $target->{$_} } grep { $_ ne 'name' } keys %$target;
%new = map { $_ => $fresh->{$_} } grep { $_ ne 'name' } keys %$fresh;
%$target = %$fresh;
return (1, $self->msg('ok'));
