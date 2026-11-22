#!/usr/bin/perl

# Copyright (c) 2026 by Phill Wolf. All rights reserved.
# The use and distribution terms for this software are covered by the Eclipse Public
# License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
# be found in the file epl-v10.html at the root of this distribution.
# By using this software in any fashion, you are agreeing to be bound by
# the terms of this license.
# You must not remove this notice, or any other, from this software.

use FindBin qw($RealBin);
use lib "$RealBin/lib";
use Encode qw(decode);
use Getopt::Long;
use Pod::Usage;
use strict;
use Term::ReadLine;

# So (count "Где") is 3, not 6, and non-ASCII prints correctly:
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

# Populate Pajaro::XYZ flags from command-line options:
my $help = 0;
my $show_version;
my $script_file;
my $do_repl;
my $carp_always;
our $compile_files = 0;
my $evaluate_command_argument=undef;
my $run_ns_main;
$Pajaro::COMPILE_PATH="$RealBin/lib";

GetOptions(
    'help|?' => \$help,
    'path=s' => \$Pajaro::PATH,
    'compile-path=s' => \$Pajaro::COMPILE_PATH,
    'verbose' => \$Pajaro::VERBOSE,
    'carp' => \$carp_always,
    'compile' => \$compile_files,
    'eval=s' => \$evaluate_command_argument,
    'main=s' => \$run_ns_main,
    'repl!' => \$do_repl,
    'version' => \$show_version)
    or pod2usage(2);
pod2usage(1) if $help;

$script_file = shift(@ARGV);

if ($carp_always) {
    require Carp::Always;
    Carp::Always->import;
}

# REPL by default if neither --version nor script:
$do_repl = 1 if (!defined($show_version)
                 && !defined($script_file)
		 && !$compile_files
		 && !$run_ns_main
                 && !defined($evaluate_command_argument));
# Show version unless doing a script or --no-version was specified:
$show_version = 1 if (!defined($show_version)
		      && !defined($run_ns_main)
		      && !defined($script_file));

# 'use Pajaro', but with 'require' so the above GetOptions will happen first:
require Pajaro;

if ($show_version) {
    clojure::core::println('Pajaro 0.0.0');
}

# Set up the 'user' namespace:
clojure::core::in_ns(clojure::core::symbol("user"));
clojure::core::refer_clojure();

# Eval expression from the command line before script or REPL
if (defined($evaluate_command_argument)) {
    # @ARGV comes in as raw bytes regardless of terminal encoding.
    my $arg = decode('UTF-8', $evaluate_command_argument);
    my $a = Pajaro::_eval_multi_line_string('arg', $arg);
    clojure::core::prn($a);
}

# Either -main, or script, or REPL:
if ($run_ns_main) {
    my $symbol = clojure::core::symbol($run_ns_main);
    # (require 'a.b.c)
    # (a.b.c/-main ...)
    my $require_sxpr = clojure::core::list
	(clojure::core::symbol('require'),
	 clojure::core::list(clojure::core::symbol('quote'), $symbol));
    clojure::core::eval($require_sxpr);
    my $main_sxpr = clojure::core::list
	(clojure::core::symbol($run_ns_main, '-main'),
	 @ARGV);
    clojure::core::eval($main_sxpr);
}
elsif ($script_file) {
    clojure::core::_eval_file($script_file, 'pl');
}
elsif ($do_repl) {
    my $term = Term::ReadLine->new('REPL');

    # Read from STDIN until a whole form has been read.
    # if EOF, ...
    # Special input line \reset
    {
	package Pajaro::REPL;

	our $STDIN_line_counter = 0;

	sub inputForm { # string to be parsed for a form, or ref=Pajaro::Reader::Nothing, or ref=Pajaro::EOFFlag
	    my $t='';
	    for (;;) {
                my $prompt;
		if ('' eq $t) {
		    $prompt = clojure::core::_print_str(clojure::core::deref($clojure::core::_STAR_ns_STAR_)).'> ';
		}
		else {
		    $prompt = '   '; # won't poison copy+paste but will still subtly alert you a paren is hanging open
		}
		$STDIN_line_counter++;
                my $u;
                if (0) { print STDERR $prompt; $u = <STDIN>; }
                else { $u = $term->readline($prompt); }
		return bless(+[],'Pajaro::EOFFlag') unless defined($u);
                # Term::ReadLine hands back raw bytes regardless of terminal
                # encoding, so non-ASCII input (e.g. "Где") would otherwise
                # be read one byte at a time instead of one code point at a time.
                $u = Encode::decode('UTF-8', $u) unless utf8::is_utf8($u);
		chomp $u;
		if ($u eq '\reset') { # in case you can't figure out how to close the parens...
		    $t = '';
		    next;
		}
		$t = "${t}\n${u}"; # important: newline so ; (the comment marker) in t won't hide u
		my $r;
		eval {
		    $r = clojure::core::read_string(
			+{'ENV'=>+{},
			      'init-cursor'=>+{'FILE'=>'STDIN',
						   'LINE'=>$STDIN_line_counter},
			      'NOTHING'=>$Pajaro::Reader::NOTHING},
			$t);
		};
		my $e = $@;
		undef $@;
		if ($e =~ /^EOF/) {
		    next; # append another line and try again
		}
		elsif ($e) {
		    if (clojure::core::deref($clojure::core::_STAR_verbose_STAR_)) {
			print STDERR 'Error<1>! '.clojure::core::print_str($e)."\n";
		    }
		    else {
			my $top_line = substr(' '.clojure::core::_print_str($e), 1);
			$top_line =~ s/\n.*//s;
			print STDERR "Error<2>! $top_line\n";
			# note: this kind of exception does not go into *e
		    }
		    $t='';
		}
		else {
		    return $t;
		}
	    }
	}

	sub register_repl_error {
	    my $e = shift;
	    $clojure::core::_STAR_e->_set_root_binding_BANG_($e);
	    my $t = clojure::core::_print_str($e);
	    if (!clojure::core::deref($clojure::core::_STAR_verbose_STAR_)) {
		$t = substr(" $t", 1);
		$t =~ s/\n.*//s;
	    }
	    print STDERR "Error<3>! $t\n";
	    $e
	}

        sub repl_eval {
            my $r = shift;
            my $res;
            undef $@;
            eval {
                $res = &clojure::core::eval($r);
            };
            if ($@) {
                my $e = $@;
		register_repl_error($e);
            }
            else {
                $clojure::core::_STAR_e->_set_root_binding_BANG_(undef);
                $clojure::core::_STAR_3->_set_root_binding_BANG_(clojure::core::deref($clojure::core::_STAR_2));
                $clojure::core::_STAR_2->_set_root_binding_BANG_(clojure::core::deref($clojure::core::_STAR_1));
                $clojure::core::_STAR_1->_set_root_binding_BANG_($res);
                # try/catch because pr-str may encounter latent lazy crashes
                {
                    local $@;
                    eval {
                        print clojure::core::pr_str($res);
                        print "\n";
                    };
                    if ($@) {
                        my $e = $@;
                        print STDERR "The result could not be printed: $e\n";
                    }
                }
            }
        }

	sub repl {
	    my $i=0;
	    my $t='';
	    for (;;) {
		my $r = inputForm();
		last if ('Pajaro::EOFFlag' eq ref($r));
		next if ('Pajaro::Reader::Nothing' eq ref($r));
		local $SIG{'INT'}=sub{die"Interrupted by signal INT"};

		# Forms will be sent to repl_eval, which transfers an error to *e.
		# If a form can't even be parsed, we catch the error here:
		{
		    local $@;
		    eval {
			Pajaro::_eval_multi_line_string('REPL', $r, \&repl_eval);
		    };
		    if ($@) {
			my $e = $@;
			register_repl_error($e);
		    }
		}
		$t='';
            }
	    print STDERR "\n";
	}
    }

    &Pajaro::REPL::repl;

} # if doing REPL

__END__

=head1 NAME

pajaro - Clojure in Perl

=head1 SYNOPSIS

C<pajaro [OPTIONS] [SCRIPT-FILE.cljpl | --main NAME.SPACE]>

Runs the script or the C<-main> function of the namespace.
Drops into a REPL if no file, expression, or main namespace is given

See option C<-h> for help.

=head1 OPTIONS

=over

=item B<--eval EXPR>

Print the value of the expression (before doing --repl, --main, or a script if any)

=item B<--repl>

Open the interactive Read, Eval, Print, Loop

=item B<--path DIR:DIR:DIR...>

"Classpath" of directories for C<import> and C<require> to search
for *.cljpl|*.cljc|*.clj files (colon-separated).
After this path, C<@INC> is searched (i.e., Perl's C<-I> option)

=item B<--main NAMESPACE>

Load the namespace and run its C<-main> function

=item B<--compile>

Should heed C<gen-class>. Currently, compiles only the core library.

=item B<--compile-path DIR>

Classpath directory in which to write compiled C<*.cljpl.pl> or C<*.cljpl.pm> files

=item B<--verbose>

Display Perl expressions transpiled from Pajaro

=item B<--version>

Identify Pajaro's version

=item B<--carp>

Uses C<Carp::Always> to produce long stack traces in more error cases

=back

=cut
