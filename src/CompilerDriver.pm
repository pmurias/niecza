package CompilerDriver;
use strict;
use warnings;
use 5.010;

use Sub::Exporter -setup => {
    exports => [ qw(compile) ]
};

use Time::HiRes 'time';
use File::Basename;
use autodie ':all';

use Body ();
use Unit ();
use Op ();
use Optimizer::Beta ();
use Optimizer::Simplifier ();
use Metamodel ();
use NAMBackend ();

use Niecza::Grammar ();
use Niecza::Actions ();

my ($srcdir, $rootdir, $builddir, $libdir);
{
    $srcdir   = dirname($INC{'CompilerDriver.pm'});
    $rootdir  = dirname($srcdir);
    $builddir = File::Spec->catdir($rootdir, "obj");
    $libdir   = File::Spec->catdir($rootdir, "lib");
}
File::Path::make_path($builddir);

sub build_file { File::Spec->catfile($builddir, $_[0]) }

sub slurp {
    my ($name) = @_;
    open my $text, "<", $name;
    local $/;
    my $bits = <$text>;
    close $text;
    $bits;
}

sub metadata_for {
    my ($unit) = @_;
    my $file = "$unit.nam";
    $file =~ s/::/./g;

    $Metamodel::units{$unit} //= NAMBackend::load(slurp(build_file($file)));
}

sub syml_for {
    my ($module, $file) = @_;
    local %Metamodel::units;
    my $meta = $Metamodel::units{$module} //=
        NAMBackend::load(slurp($file));

    if ($meta->name ne $module) {
        Carp::cluck("syml_for incoherence");
    }

    for my $dmod (keys %{ $meta->tdeps }) {
        next if $dmod eq $module;
        $Metamodel::units{$dmod} = CompilerDriver::metadata_for($dmod);
    }

    return $meta->create_syml;
}

sub get_perl6lib {
    File::Spec->curdir, $libdir
}

sub find_module {
    my $module = shift;
    my $issetting = shift;

    my @toks = split '::', $module;
    my $end = pop @toks;

    for my $d (get_perl6lib) {
        for my $ext (qw( .setting .pm6 .pm )) {
            next if defined($issetting) && ($issetting xor ($ext eq '.setting'));

            my $file = File::Spec->catfile($d, @toks, "$end$ext");
            next unless -f $file;

            if ($ext eq '.pm') {
                local $/;
                open my $pm, "<", $file or next;
                my $pmtx = <$pm>;
                close $pm;
                next if $pmtx =~ /^\s*package\s+\w+\s*;/m; # ignore p5 code
            }

            return $file;
        }
    }

    return;
}

{
    package
        CursorBase;
    no warnings 'redefine';

    sub sys_save_syml {
        my ($self, $all) = @_;
    }

    sub sys_do_compile_module {
        my ($self, $mod, $syml, $file) = @_;
        CompilerDriver::compile(name => $mod, stagetime => $::stagetime);
    }

    sub sys_load_modinfo {
        my $self = shift;
        my $module = shift;

        # these are handled in the compiler itself
        return { } if $module eq 'MONKEY_TYPING' || $module eq 'lib' ||
            $module eq 'fatal';

        my $csmod = $module;
        $csmod =~ s/::/./g;
        my ($namfile) = CompilerDriver::build_file("$csmod.nam");
        my ($modfile) = CompilerDriver::find_module($module, 0) or do {
            $self->sorry("Cannot locate module $module");
            return undef;
        };

        REUSE: {
            last REUSE unless -f $namfile;
            my $meta = CompilerDriver::metadata_for($module);

            for my $dmod ($module, keys %{ $meta->tdeps }) {
                my $u = CompilerDriver::metadata_for($dmod);
                my ($dpath, $dtime) = @{ $meta->tdeps->{$dmod} //
                    [ $meta->filename, $meta->modtime ] };

                my ($npath) = CompilerDriver::find_module($dmod, undef) or do {
                    $self->sorry("Dependancy $dmod of $module cannot be located");
                    return undef;
                };

                $npath = Cwd::realpath($npath);
                if ($npath ne $dpath) {
                    print STDERR "Recompiling $module because dependancy $dmod now points to $npath, was $dpath\n";
                    last REUSE;
                }

                my $ntime = (stat $npath)[9];
                if ($ntime ne $dtime) {
                    print STDERR "Recompiling $module because dependancy $dmod is newer ($dtime -> $ntime)\n";
                    last REUSE;
                }
            }

            return CompilerDriver::syml_for($module, $namfile);
        }

        $self->sys_compile_module($module, $namfile, $modfile);
        CompilerDriver::syml_for($module, $namfile);
    }

    sub load_lex {
        my $self = shift;
        my $setting = shift;
        my $settingx = $setting;
        $settingx =~ s/::/./g;

        if ($setting eq 'NULL') {
            my $id = "MY:file<NULL.pad>:line(1):pos(0)";
            my $core = Stash->new('!id' => [$id], '!file' => 'NULL.pad',
                '!line' => 1);
            return Stash->new('CORE' => $core, 'MY:file<NULL.pad>' => $core,
                'SETTING' => $core, $id => $core);
        }

        my $astf = File::Spec->catfile($builddir, "$settingx.nam");
        if (-e $astf) {
            return CompilerDriver::syml_for($setting, $astf);
        }

        $self->sorry("Unable to load setting $setting.");
        return $self->load_lex("NULL");
    }
}

sub compile {
    my %args = @_;

    my ($name, $file, $code, $lang, $safe, $setting) =
        @args{'name', 'file', 'code', 'lang', 'safe', 'setting'};

    $lang //= 'CORE';

    if (defined($name) + defined($file) + defined($code) != 1) {
        Carp::croak("Exactly one of name, file, and code must be used");
    }

    my $path = $file;
    if (defined($name)) {
        $path = find_module($name, $setting // 0);
        if (!defined($path)) {
            Carp::croak("Module $name not found");
        }
    }

    local %Metamodel::units;
    local $::stagetime = $args{stagetime};
    local $::SETTING_UNIT;
    local $::YOU_WERE_HERE;
    local $::UNITNAME = $name // 'MAIN';
    $::UNITNAME =~ s/::/./g;
    local $::SAFEMODE = $safe;
    $STD::ALL = {};
    my ($filename, $modtime);

    if ($lang ne 'NULL') {
        $::SETTING_UNIT = $lang;
    }

    if (defined($name)) {
        $filename = Cwd::realpath($path);
        $modtime  = ((stat $filename)[9]);
    }

    my ($m, $a) = defined($path) ? (parsefile => $path) : (parse => $code);

    my $ast;
    my $basename = $::UNITNAME;
    my $namfile = File::Spec->catfile($builddir, "$basename.nam");
    my $outfile = File::Spec->catfile($builddir,
        $basename . (defined($name) ? ".dll" : ".exe"));

    my @phases = (
        [ 'parse', sub {
            $ast = Niecza::Grammar->$m($a, setting => $lang,
                actions => 'Niecza::Actions')->{_ast}; } ],
        [ 'begin', sub {
            $ast = $ast->begin;
            if (defined $name) {
                $ast->filename($filename);
                $ast->modtime($modtime);
            }
        } ],
        [ 'beta', sub { Optimizer::Beta::run($ast) } ],
        [ 'simpl', sub { Optimizer::Simplifier::run($ast) } ],
        [ 'nam', sub { $ast = [$ast, NAMBackend::run($ast)] } ],
        [ 'writenam', sub {
            open my $fh, ">", $namfile;
            print $fh $ast->[1];
            close $fh;
            $ast = undef;
        } ],
        [ 'codegen', sub {
            my @args = ("mono",
                File::Spec->catfile($builddir, "CLRBackend.exe"), $builddir,
                "$basename.nam", (defined($name) ? ("$basename.dll", "0") :
                    ("$basename.exe", "1")));
            print STDERR "@args\n" if $args{stagetime};
            system @args;
            $ast = undef;
        } ],
        [ 'aot', sub {
            system "mono", "--aot", $outfile;
        } ]);

    for my $p (@phases) {
        next if $p->[0] eq 'aot' && !$args{aot};
        my $t1 = time if $args{stagetime};
        $p->[1]->();
        my $t2 = time if $args{stagetime};
        printf "%-20s: %gs\n", "$basename " . $p->[0],
            $t2 - $t1 if $args{stagetime};
        if ($args{stopafter} && $args{stopafter} eq $p->[0]) {
            if ($ast && $args{stopafter} ne 'writenam') {
                print STDERR YAML::XS::Dump($ast);
            }
            return;
        }
    }
}

1;
