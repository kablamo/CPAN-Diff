package CPAN::Diff;
use Moo;

use Config;
use ExtUtils::Installed;
use HTTP::Tiny;
use Module::Extract::Namespaces;
use Module::Metadata;
use Parse::CPAN::Packages::Fast;
use version;

our $VERSION = "0.03";

has mirror               => (is => 'ro', builder => 1);
has exclude_core         => (is => 'rw');
has local_lib            => (is => 'rw');
has self_contained       => (is => 'rw');

has extra_modules        => (is => 'rw', lazy => 1, builder => 1);
has newer_modules        => (is => 'rw', lazy => 1, builder => 1);
has older_modules        => (is => 'rw', lazy => 1, builder => 1);

has core_modules         => (is => 'rw', lazy => 1, builder => 1);
has tmp_dir              => (is => 'rw', builder => 1);
has module_cache         => (is => 'rw', lazy => 1, builder => 1);

sub _build_mirror       { "http://cpan.org" };
sub _build_tmp_dir      { "/tmp" };
sub _build_core_modules { 
    return undef unless shift->exclude_core;
    require Module::CoreList;
    $Module::CoreList::version{$]};
}

sub _build_extra_modules { shift->module_cache->{extra} }
sub _build_newer_modules { shift->module_cache->{newer} }
sub _build_older_modules { shift->module_cache->{older} }

sub _build_module_cache  {
    my ($self)     = @_;
    my @inc        = $self->make_inc;
    my $cpan       = $self->cpan;
    my @local_pkgs = $self->get_local_pkgs(@inc);
print "runnnnnnnnnnnnnn\n";

    for my $local_pkg (sort @local_pkgs) {
        my $pkg = $cpan->package($local_pkg);
        my $local_version = $self->local_version_for($local_pkg, \@inc) || next;
        next unless $local_version =~ /[0-9]/;
        next if $self->core_modules && $self->core_modules->{$local_pkg};
        my $pkg_metadata  = {
            name          => $local_pkg,
            local_version => $local_version,
            cpan_version  => $pkg ? $pkg->version : undef,
            dist          => $pkg ? $pkg->distribution : undef,
        };

        if (!$pkg) {
            push @{ $self->extra_modules }, $pkg_metadata;
        }
        else {
            my $result = $self->compare_version($local_version, $pkg->version);
            next if $result == 0;
            push @{ $self->newer_modules }, $pkg_metadata if $result == 1;
            push @{ $self->older_modules }, $pkg_metadata if $result == -1;
        }
    }

    return $self;
}

sub cpan {
    my $self = shift;
    my $file;

    if ($self->mirror =~ m|^file\://(.*)|i) {
        $file = $1;
    }
    else {
        my $uri = $self->mirror;
        $uri =~ s|/$||;
        $uri = "$uri/modules/02packages.details.txt.gz";

        my $unique = $uri;
        $unique =~ s|/|_|g;
        $file = $self->tmp_dir . "/" . $unique;

        my $res = HTTP::Tiny->new->mirror($uri, $file);
        die "failed to download $uri to $file:\n$res->{status} $res->{reason}\n"
            unless $res->{success};
    }
    return Parse::CPAN::Packages::Fast->new($file);
}

sub compare_version {
    my ($self, $local_version, $version) = @_;
    return 0 if $local_version eq $version;

    my $local_version_obj = eval { version->new($local_version) } || version->new(permissive_filter($local_version));
    my $version_obj       = eval { version->new($version) }       || version->new(permissive_filter($version));

    return  1 if $local_version_obj  > $version_obj;
    return -1 if $local_version_obj  < $version_obj;
    return  0 if $local_version_obj == $version_obj;
}

# for broken packages.
sub permissive_filter {
    local $_ = $_[0];
    s/^[Vv](\d)/$1/;                   # Bioinf V2.0
    s/^(\d+)_(\d+)$/$1.$2/;            # VMS-IndexedFile 0_02
    s/-[a-zA-Z]+$//;                   # Math-Polygon-Tree 0.035-withoutworldwriteables
    s/([a-j])/ord($1)-ord('a')/gie;    # DBD-Solid 0.20a
    s/[_h-z-]/./gi;                    # makepp 1.50.2vs.070506
    s/\.{2,}/./g;
    $_;
}

sub local_version_for {
    my ($self, $pkg, $inc) = @_;

    local $SIG{__WARN__} = sub {};
    my $meta = Module::Metadata->new_from_module($pkg, inc => $inc);
    $meta ? $meta->version($pkg) : undef;
}

sub get_local_pkgs {
    my ($self, @inc) = @_;
    # TODO: if you want to filter the target modules, you can change them here.
    ExtUtils::Installed->new(skip_cwd => 1, inc_override => \@inc)->modules;
}

sub make_inc {
    my ($self) = @_;

    if ($self->local_lib) {
        require local::lib;
        my @modified_inc = (
            local::lib->install_base_perl_path($self->local_lib),
            local::lib->install_base_arch_path($self->local_lib),
        );
        if ($self->self_contained) {
            push @modified_inc, @Config{qw(privlibexp archlibexp)};
        } else {
            push @modified_inc, @INC;
        }
        return @modified_inc;
    } else {
        return @INC;
    }
}

1;
__END__

=encoding utf-8

=head1 NAME

CPAN::Diff - Compare local Perl packages/versions with a CPAN

=head1 SYNOPSIS

    use CPAN::Diff;

    # all params are optional
    # mirror defaults to http://cpan.org
    my $diff = CPAN::Diff->new(
        mirror         => 'https://darkpan.mycompany.com'
        local_lib      => 'local',
        self_contained => 1,
        exclude_core   => 1,
    );

    # local modules which are not in your darkpan
    # returns an arrayref of hashes
    my $extra = $diff->extra_modules;  
    print "$_->{name}: $_->{version}\n" for @$extra;

    # local modules which have different versions than your darkpan
    # returns an arrayref of hashes
    my $older = $diff->older_modules; 
    print "$_->{name}: $_->{cpan_version}\t$_->{local_version}\n"
        for @$older;

    # local modules which have different versions than your darkpan
    # returns an arrayref of hashes
    my $newer = $diff->newer_modules; 
    print "$_->{name}: $_->{cpan_version}\t$_->{local_version}\n"
        for @$newer;

=head1 DESCRIPTION

Discover which Perl packages/versions are different in your environment compared to
CPAN or your darkpan (pinto or orepan2 or whatever).

This module comes with a handy script as well: L<cpan-diff>

This modules steals a lot of code from L<cpan-outdated>.

=head1 LICENSE

Copyright (C) Eric Johnson.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Eric Johnson E<lt>eric.git@iijo.orgE<gt>

=cut

