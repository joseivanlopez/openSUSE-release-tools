#! /usr/bin/perl

use File::Basename;
use File::Temp qw/ tempdir  /;
use XML::Simple;
use Data::Dumper;
use Cwd;
use Text::Diff;
BEGIN {
    unshift @INC, ($::ENV{'BUILD_DIR'} || '/usr/lib/build');
}
use Build;

my $ret = 0;

my $old = $ARGV[0];
my $dir = $ARGV[1];
my $bname = basename($dir);

if (-f "$dir/_service") {
    my $service = XMLin("$dir/_service", ForceArray => ['service']);
    while( my ($name, $s) = each %{$service->{service}} ) {
        my $mode = $s->{mode} || '';
        next if ($mode eq "localonly" || $mode eq "disabled" || $mode eq "buildtime" || $mode eq "manual" );
        print "Services are only allowed if they are mode='localonly', 'disabled', 'manual' or 'buildtime'. Please change the mode of $name and use `osc service localrun/disabledrun`.\n";
        $ret = 1;
    }
    # move it away to have full service from source validator
    rename("$dir/_service", "$dir/_service.bak") || die "rename failed";
}

for my $file (glob("$dir/_service:*")) {
    $file=basename($file);
    print "Found _service generated file $file in checkout. Please clean this up first.";
    $ret = 1;
}

my @specs = map basename($_), glob("$dir/*.spec");

if (@specs) {
    if (!-f "$dir/$bname.changes") {
        print "$bname.changes is missing. A package submitted as FooBar needs to have a FooBar.changes file with a format created by `osc vc`.\n";
        $ret = 1;
    }

    if (!-f "$dir/$bname.spec") {
        print "$bname.spec is missing. A package submitted as FooBar needs to have a FooBar.spec file.\n";
        $ret = 1;
    }
    exit($ret) if ($ret);
} else {
    # package without spec files, eg kiwi only
    exit($ret);
}

open(SPEC, "$dir/$bname.spec");
my $spec = join("", <SPEC>);
close(SPEC);

if ($spec !~ m/#[*\s]+Copyright\s/) {
    print "$bname.spec does not appear to contain a Copyright comment. Please stick to the format\n\n";
    print "# Copyright (c) 2011 Stephan Kulow\n\n";
    print "or use osc service runall format_spec_file\n";
    $ret = 1;
}

if ($spec =~ m/\nVendor:/) {
    print "$bname.spec contains a Vendor line, this is forbidden.\n";
    $ret = 1;
}

# Check that we have for each spec file a changes file - and that at least one
# contains changes
my $changes_updated = 0;
for my $spec (@specs) {
    $changes = $spec;
    $changes =~ s/\.spec$/.changes/;

    # new or deleted .changes files also count
    if ((-f "$old/$changes") != (-f "$dir/$changes")) {
        $changes_updated = 1;
        last;
    }
    elsif ((-f "$old/$changes") && (-f "$dir/$changes")) {
        if (system(("cmp", "-s", "$old/$changes", "$dir/$changes"))) {
            $changes_updated = 1;
            last;
        }
    }
}

if (!$changes_updated) {
    print "No changelog. Please use 'osc vc' to update the changes file(s).\n";
    $ret = 1;
}

if ($spec !~ m/\n%changelog\s/ && $spec != m/\n%changelog$/) {
    print "$bname.spec does not contain a %changelog line. We don't want a changelog in the spec file, but the %changelog section needs to be present\n";
    $ret = 1;
}

if ($spec !~ m/(#[^\n]*license)/i) {
    print "$bname.spec does not appear to have a license. The file needs to contain a free software license\n";
    print "Suggestion: use \"osc service runall format_spec_file\" to get our default license or\n";
    print "the minimal license:\n\n";
    print "# This file is under MIT license\n";
    $ret = 1;
}

my %patches = ();

for my $test (glob("/usr/lib/obs/service/source_validators/*")) {
    next if (!-f "$test");
    my $checkivsd = `/bin/bash $test --batchmode $dir $old < /dev/null 2>&1`;
    if ($?) {
        print "Source validator failed. Try \"osc service runall source_validator\"\n";
        print $checkivsd;
        print "\n";
        $ret = 1;
    }
    else {
        for my $line (split(/\n/, $checkivsd)) {
            # pimp up some warnings
            if ($line =~ m/Attention.*not mentioned/) {
                $line =~ s,\(W\) ,,;
                print "$line\n";
                $ret = 1;
            }
        }
    }
}

my $odir = getcwd();

chdir($dir) || die "chdir $dir failed";
for my $patch (glob("*.diff *.patch *.dif")) {
    $patches{$patch} = 'current';
}
chdir($odir) || die "chdir $odir failed";

if (-d "$old") {

    chdir($old) || die "chdir $old failed";
    my $cf = Build::read_config("x86_64", "/usr/lib/build/configs/default.conf");

    my %thash = ();
    my %rhash = ();
    for my $spec (glob("*.spec")) {
        my $ps = Build::Rpm::parse($cf, $spec);

        while (my ($k, $v) = each %$ps) {
            if ($k =~ m/^source/) {
                $thash{$v} = 1;
            }
        }
    }
    for my $patch (glob("*.diff *.patch *.dif")) {
        if ($patches{$patch}) {
            delete $patches{$patch};
        }
        else {
            $patches{$patch} = 'old';
        }
    }

    chdir($odir) || die "chdir $odir failed";
    chdir($dir) || die "chdir $dir failed";
    for my $spec (glob("*.spec")) {
        my $ps = Build::Rpm::parse($cf, $spec);
        open(OSPEC, "$spec");
        open(NSPEC, ">$spec.new");
        while (<OSPEC>) {
            chomp;
            if (m/^Source/) {
                my $line = $_;
                $line =~ s/^(Source[0-9]*)\s*:\s*//;
                if ($patches{$line}) {
                   delete $patches{$line};
                }
                my $prefix = $1;
                my $parsedline = $ps->{lc $prefix};
                if (defined $thash{$parsedline}) {
                    my $file = $line;
                    my $bname = basename($file);
                    print NSPEC "$prefix: $bname\n";
                }
                else {
                    print NSPEC "$_\n";
                }
            }
            else {
                print NSPEC "$_\n";
            }
        }
        close(OSPEC);
        close(NSPEC);
        system(("cp", "$spec", "$spec.beforeurlstrip"));
        rename("$spec.new", "$spec") || die "rename failed";
    }

    chdir($dir);
    my @changes = glob("*.changes");
    chdir($odir);

    if (%patches) {
        # parse changes
        for my $changes (@changes) {
            my $diff = "";
            if (! -e "$old/$changes") {
                $diff = diff "/dev/null", "$dir/$changes";
            }
            else {
                $diff = diff "$old/$changes", "$dir/$changes";
            }
            for my $line (split(/\n/, $diff)) {
                next unless $line =~ m/^\+/;
                $line =~ s/^\+//;
                for my $patch (keys %patches) {
                    if (index($line, $patch) != -1) {
                        delete $patches{$patch};
                    }
                }
            }
        }
    }
    # still some left?
    if (%patches) {
        $ret = 1;
        for my $patch (keys %patches) {
            # wording stolen from Raymond's declines :)
            if ($patches{$patch} eq 'current') {
                print "A patch ($patch) is being added without this addition being mentioned in the changelog.\n";
            }
            else {
                print "A patch ($patch) is being deleted without this removal being mentioned in the changelog.\n";
            }
        }
    }
}

my $odir2 = getcwd;
my $tmpdir = tempdir("obs-XXXXXXX", TMPDIR => 1, CLEANUP => 1);
chdir($dir) || die 'tempdir failed';
if (system("/usr/lib/obs/service/download_files","--enforceupstream", "yes", "--enforcelocal", "yes", "--outdir", $tmpdir)) {
    print "Source URLs are not valid. Try \"osc service runall download_files\".\n";
    $ret = 2;
}
chdir($odir2);

for my $rpmlint (glob("$dir/*rpmlintrc")) {
    open(RPMLINTRC, $rpmlint);
    while (<RPMLINTRC>) {
        if (m/^\s*setBadness/) {
            print "For Factory submissions, you cannot use setBadness. Use filters in $rpmlint.\n";
            $ret = 1;
        }
    }
}

exit($ret) if $ret;

# now check if the change is small enough to warrent a review-by-mail
exit(0) unless -d $old;

sub prepare_package($) {

    my $files = shift;

    unlink glob "*.changes"; # ignore changes
    unlink glob "*.tar.*"; # we can't diff them anyway
    unlink glob "*.zip";

    # restore original spec file
    for my $spec (glob("*.beforeurlstrip")) {
        my $oldname = $spec;
        $oldname =~ s/.beforeurlstrip//;
        rename($spec, $oldname);
    }

    for my $spec (glob("*.spec")) {
        open(SPEC, "/usr/lib/obs/service/format_spec_file.files/prepare_spec $spec | grep -v '^#' |");
        my @lines = <SPEC>;
        close(SPEC);
        open(SPEC, ">", $spec);
        print SPEC join('', @lines);
        close(SPEC);
    }
}

# move it back so we also diff the service file
if (-f "$dir/_service.bak") {
    rename("$dir/_service.bak", "$dir/_service") || die "rename failed";
}

my %files;
chdir($old);
prepare_package(\%files);
chdir($odir2);
chdir($dir);
prepare_package(\%files);
exit(0);
