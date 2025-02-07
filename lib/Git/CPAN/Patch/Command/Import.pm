package Git::CPAN::Patch::Command::Import;
#ABSTRACT: Import a module into a git repository

use 5.20.0;

use strict;
use warnings;
use File::Temp qw/ tempdir /;
use Git::Repository;
use Git::CPAN::Patch::Import;
use File::chdir;
use Git::CPAN::Patch::Release;
use Path::Class qw/ dir /;
use MetaCPAN::Client;

# TODO Path::Class => Path::Tiny

use MooseX::App::Command;

extends 'Git::CPAN::Patch';
with 'Git::CPAN::Patch::Role::Git';

has tmpdir => (
  is => 'ro',
  isa => 'Path::Tiny',
  lazy => 1,
  default => sub {
    return Path::Tiny->tempdir();
  }
);

use experimental qw(smartmatch signatures);

our $PERL_GIT_URL = 'git://perl5.git.perl.org/perl.git';

option 'norepository' => (
    is => 'ro',
    isa => 'Bool',
    default => 0,
    documentation => "don't clone git repository",
);

option 'latest' => (
    is => 'ro',
    isa => 'Bool',
    default => 0,
    documentation => 'only pick latest release, if clone from CPAN',
);

option check => (
    is => 'ro',
    isa => 'Bool',
    default => 1,
    cmd_negate => 'nocheck',
    documentation => q{Verifies that the imported version is greater than what is already imported},
);

option parent  => (
    is => 'ro',
    isa => 'ArrayRef',
    default => sub { [] },
    documentation => q{Parent of the imported release (can have more than one)},
);

parameter thing_to_import => (
    is  => 'rw',
    isa => 'Str',
    required => 0,
);

has metacpan => (
    is => 'ro',
    default => sub {
        MetaCPAN::Client->new;
    },
);

option author_name => (
    is => 'ro',
    documentation => "explicitly set the author's name",
);

option author_email => (
    is => 'ro',
    documentation => "explicitly set the author's email",
);

sub get_releases_from_url($self,$url) {
    require LWP::Simple;

    ( my $name = $url ) =~ s#^.*/##;
    my $destination = $self->tmpdir . '/'.$name;

    say "copying '$url' to '$destination'";

    LWP::Simple::mirror( $url => $destination )
        or die "Failed to mirror $url\n";

    return Git::CPAN::Patch::Release->new(
        metacpan => $self->metacpan,
        tarball => $destination
    );
}

sub get_releases_from_local_file($self,$path) {
    return Git::CPAN::Patch::Release->new( metacpan => $self->metacpan, tarball => $path );
}

sub clone_git_repo($self,$release,$url) {
    $self->git_run( 'remote', 'add', 'cpan', $url );
    {
        # git will output the tags on STDERR
        local *STDERR;
        open STDERR, '>', \my $err;
        $self->git_run( 'fetch', 'cpan' );
        say $err;
    }
    $self->git_run( config => 'cpan.module-name', $release->dist_name );
}

sub looks_like_git {
    my $repo = shift or return;

    return 1 if $repo->{type} eq 'git';

    return $repo->{url} =~ /github\.com|\.git$/;
}

sub get_releases_from_cpan($self,$dist_or_module) {

    # is it a module belonging to a distribution?
    my $dist = eval{ $self->metacpan->module($dist_or_module)->data->{distribution}
    } || $dist_or_module;

     if ( $dist eq 'perl' ) {
        die "$dist_or_module is a core modules, ",
            "clone perl from $PERL_GIT_URL instead.\n";
    }

    if( my $latest_release = !$self->norepository && $self->metacpan->release($dist)) {
        my $repo = $latest_release->data->{metadata}{resources}{repository};
        if ( looks_like_git($repo) ) {
            say "Git repository found: ", $repo->{url};
            $self->clone_git_repo(Git::CPAN::Patch::Release->new(
                metacpan => $self->metacpan,
                dist_name => $dist,
                meta_info => $latest_release,
            ),$repo->{url});
            return;
        }
    }

    if ( $self->latest ) {
        my $rel = $self->metacpan->release($dist);
        return Git::CPAN::Patch::Release->new(
                metacpan => $self->metacpan,
            meta_info => $rel->data,
            map { $_ => $rel->data->{$_} } qw/ name author date download_url version /
        );
    }

    my $releases = $self->metacpan->release( {
        distribution => $dist
    }) or die "could not find release for '$dist_or_module' on metacpan\n";

    my @releases;

    while( my $r = $releases->next ) {
        push @releases, Git::CPAN::Patch::Release->new(
                metacpan => $self->metacpan,
            meta_info => $r->data
        );
    }

    return sort { $a->date cmp $b->date } @releases;
}

sub releases_to_import ($self) {
    given ( $self->thing_to_import ) {
        when ( qr/^(?:https?|file|ftp)::/ ) {
            return $self->get_releases_from_url( $_ );
        }
        when ( -f $_ ) {
            return $self->get_releases_from_local_file( $_ );
        }
        default {
            return $self->get_releases_from_cpan($_);
        }
    }
}

sub import_release($self,$release) {
    my $import_version = $release->dist_version;

    if ( $self->check and $self->last_imported_version ) {
        return say $release->dist_name . " $import_version has already been imported\n"
            if $import_version == $self->last_imported_version;

        return say sprintf "last imported version %s is more recent than %s"
            . ", can't import",
            $self->last_imported_version, $import_version
          if $import_version <= $self->last_imported_version;
    }

    # create a tree object for the CPAN module
    # this imports the source code without touching the user's working directory or
    # index

    my $tree = do {
        # don't overwrite the user's index
        local $ENV{GIT_INDEX_FILE} = $self->tmpdir . "/temp_git_index";
        local $ENV{GIT_DIR} = dir($self->root . '/.git')->absolute->stringify;
        local $ENV{GIT_WORK_TREE} = $release->extracted_dir;

        local $CWD = $release->extracted_dir;

        my $write_tree_repo = Git::Repository->new( work_tree => $CWD );

        $write_tree_repo->run( qw(add -v --all --force .) );
        $write_tree_repo->run( "write-tree" );
    };

    # create a commit for the imported tree object and write it into
    # refs/heads/cpan/master
    {
        local %ENV = %ENV;

        # TODO authors and author_date

        # create the commit object
        $ENV{GIT_AUTHOR_NAME}  = $self->author_name  || $release->author_name  || $ENV{GIT_AUTHOR_NAME};
        $ENV{GIT_AUTHOR_EMAIL} = $self->author_email || $release->author_email || $ENV{GIT_AUTHOR_EMAIL};
        $ENV{GIT_AUTHOR_DATE}  = $release->date if $release->date;

        my @parents = grep { $_ } $self->last_commit, @{ $self->parent };

        my $message = sprintf "%s %s %s\n",
            ( $self->first_import ? 'initial import of' : 'import' ),
            $release->dist_name, $release->dist_version;

        no warnings 'uninitialized';
        $message .= <<"END";

git-cpan-module:   @{[ $release->dist_name ]}
git-cpan-version:  @{[ $release->dist_version ]}
git-cpan-authorid: @{[ $release->author_cpan ]}

END

        my $commit = $self->git_run(
            { input => $message },
            'commit-tree', $tree, map { ( -p => $_ ) } @parents );

        # finally, update the fake remote branch and create a tag for convenience

        print $self->git_run('update-ref', '-m' => "import " . $release->dist_name, 'refs/remotes/cpan/master', $commit );

        my $tag_name = $release->dist_version =~ /^v/ ? $release->dist_version : 'v'.$release->dist_version;
        print $self->git_run( tag => $tag_name, $commit );

        say "created tag '@{[ $tag_name ]}' ($commit)";
    }

    $self->git_run( config => 'cpan.module-name', $release->dist_name );
}

sub run ($self) {
    my @releases = $self->releases_to_import;

    for my $r ( @releases ) {
        eval { $self->import_release($r) };
        if ( $@ ) {
            warn "failed to import release, skipping...\n$@\n";
        }
    }
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=pod


=head1 SYNOPSIS

    # takes any string CPANPLUS handles:

    % git-cpan import Foo::Bar
    % git-cpan import A/AU/AUTHORID/Foo-Bar-0.03.tar.gz
    % git-cpan import http://backpan.cpan.org/authors/id/A/AU/AUTHORID/Foo-Bar-0.03.tar.gz

    # If the repository is already initialized, can be run with no arguments to
    # import the latest version
    git-cpan import


=head1 DESCRIPTION

This command is used internally by C<git-cpan-init>, C<git-cpan-update> and
C<git-backpan-init>.

This command takes a tarball, extracts it, and imports it into the repository.

It is only possible to update to a newer version of a module.

The module history is tracked in C<refs/remotes/cpan/master>.

Tags are created for each version of the module.

This command does not touch the working directory, and is safe to run even if
you have pending work.

=head1 OPTIONS

=over

=item --check, --nocheck

Explicitly enables/disables version checking.  If version checking is
enabled, which is the default, git-cpan-import will refuse to import a
version of the package
that has a smaller version number than the HEAD of the branch I<cpan/master>.

=item --parent

Allows adding extra parents when
importing, so that when a patch has been incorporated into an upstream
version the generated commit is like a merge commit, incorporating both
the CPAN history and the user's local history.

For example, this will set the current HEAD of the master branch as a parent of
the imported CPAN package:

    $ git checkout master
    $ git-cpan import --parent HEAD My-Module

More than one '--parent' can be specified.

=item --author_name

Forces the author name to the given value, instead of trying to resolve it from
the release metadata.

=item --author_email

Forces the author email to the given value, instead of trying to resolve it from
the release metadata.

=back

=head1 AUTHORS

Yuval Kogman C<< <nothingmuch@woobling.org> >>

Yanick Champoux C<< <yanick@cpan.org> >>


=head1 SEE ALSO

L<Git::CPAN::Patch>

=cut
