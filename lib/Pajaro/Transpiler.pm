# Copyright (c) 2026 by Phill Wolf. All rights reserved.
# The use and distribution terms for this software are covered by the Eclipse Public
# License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
# be found in the file epl-v10.html at the root of this distribution.
# By using this software in any fashion, you are agreeing to be bound by
# the terms of this license.
# You must not remove this notice, or any other, from this software.

package Pajaro::Transpiler;

=pod

The Pajaro Transpiler transforms Clojure expressions
(as data structures such as lists)
into Pajaro::Salt::Term nodes which can be serialized to
Perl code.

=cut

use strict;
use Sub::Util qw(set_subname);
use Pajaro::Munge qw(munge keyword_munge);
use Pajaro::Salt;
use experimental 'builtin';

Pajaro::_setup_protocol('Pajaro.Transpiler.ITranspile',
                      +{'_transpile1'=>'Perl-writer node'});

our $CITATION_UNAVAILABLE = +[undef, undef];

sub _transpile_fn_args_assignment { # the values will be in Perl list @_ and the varargs HAVE ALREADY been collected into a Clojure Vector
    my $arglist_vec = shift;
    my ($a_cite, $a_user_meta) = Pajaro::_citation_and_user_meta($arglist_vec);
    my @lexical_assignments;
    for(my $arglist_seq = clojure::core::seq($arglist_vec); $arglist_seq; $arglist_seq = &clojure::core::next($arglist_seq)) {
        last unless defined($arglist_seq);
        my $k = clojure::core::first($arglist_seq);
        die 'Expected simple symbol but got '.clojure::core::pr_str($k) unless clojure::core::simple_symbol_QMARK_($k);
	if ('&' eq clojure::core::name($k)) {
            # ignore
        }
        else {
	    my ($k_cite, $k_user_meta) = Pajaro::_citation_and_user_meta($k);
            my $kp = munge(clojure::core::name($k));
            my $pw_source_of_value;
            $pw_source_of_value = Pajaro::Salt::rawExpression($k_cite, 'shift');
            push(@lexical_assignments, Pajaro::Salt::statement($a_cite, Pajaro::Salt::assign($k_cite, '$'.$kp, $pw_source_of_value)));
	}
    }
    push(@lexical_assignments, Pajaro::Salt::statement($a_cite,Pajaro::Salt::rawExpression($a_cite, ''))); # force the last actual shift to get a semicolon
    return Pajaro::Salt::statements($a_cite, @lexical_assignments);
}

# Grab 1st term from list if it satisfies the predicate
sub _peel_selectively {
    my $predicate = shift;
    my $list = shift;
    my $first = clojure::core::first($list);
    if (&{$predicate}($first)) {
        return ($first, clojure::core::rest($list));
    }
    else {
        return (undef, $list);
    }
}

# Grab 1st term from list and die unless it satisfies the predicate
sub _peel_critically {
    my $predicate = shift;
    my $list = shift;
    my $first = clojure::core::first($list);
    if (&{$predicate}($first)) {
        return ($first, clojure::core::rest($list));
    }
    else {
        die ("Disappointed by type of ".clojure::core::pr_str($first));
    }
}

# Special forms (sub pattern _special_xyz):

sub _special_var {
    my $x0 = shift; # the (var ...) form
    my $opts = shift;
    my $env = shift; # Perl map of local/let bindings
    my $x = $x0;
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    my ($_var, $x) = _peel_critically(\&clojure::core::simple_symbol_QMARK_, $x); # var
    my ($symbol, $x) = _peel_critically(\&clojure::core::symbol_QMARK_, $x);
    my $resolved = clojure::core::resolve($symbol);
    if (!$resolved) {
        die("Unable to resolve ".clojure::core::pr_str($symbol)." in this context");
    }
    elsif (clojure::core::var_QMARK_($resolved)) {
        Pajaro::Salt::verbatimPerl($x_cite, Pajaro::_Var_to_perl($resolved))
    }
    else {
        die("Hmm, resolved symbol but not to a Var: ".clojure::core::pr_str($symbol));
    }
}

# (. Ty.pe new x y z)
# (. instance -interopMemberField)

# - special form => Ty::pe->new(x, y, z)
sub _special__DOT_ {
    my $x0 = shift; # the (. Ty.pe x y z) form
    my $opts = shift;
    my $env = shift; # Perl map of local/let bindings
    my $x = $x0;
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    my $_dot;
    ($_dot, $x) = _peel_critically(\&clojure::core::simple_symbol_QMARK_, $x); # consume the dot
    my $instance_or_type_form = &clojure::core::first($x);
    $x = &clojure::core::next($x);
    my $maybe_qual_clj_sym = $instance_or_type_form if(&clojure::core::symbol_QMARK_($instance_or_type_form));
    my $typ_clj_sym;
    my $refersToType;
    my $refersToInstance;
    my $typ_pl;
    if ($maybe_qual_clj_sym && clojure::core::qualified_symbol_QMARK_($maybe_qual_clj_sym)) {
	$typ_clj_sym = $maybe_qual_clj_sym;
	$refersToInstance=1;
    }
    elsif ($maybe_qual_clj_sym) {
	$typ_clj_sym = $maybe_qual_clj_sym;
	my $typ_clj_unqual = clojure::core::name($typ_clj_sym);
	if (exists($$env{$typ_clj_unqual})) {
	    $refersToInstance=1;
	}
	else {
	    # Fishing for a type, If it does not already have ::, prepend *ns*
	    my $typ_clj_dq = $typ_clj_unqual;
	    if ($typ_clj_unqual !~ /[.]/) {
		$typ_clj_dq = clojure::core::name(clojure::core::ns_name(clojure::core::deref($clojure::core::_STAR_ns_STAR_))).'.'.$typ_clj_unqual;
	    }
	    $typ_pl = Pajaro::_namespace_munge(munge($typ_clj_dq));
	    $typ_pl =~ s/^Perl:://;
	    (my $typ_pl_parent, my $typ_pl_relative) = ($typ_pl =~ /(^.*?)([^:]+)$/);
	    {
		if (!$typ_pl_parent) { $typ_pl_parent = 'main::' }
		no strict 'refs';
		if (exists(${"${typ_pl_parent}"}{"${typ_pl_relative}::"})) {
		    $refersToType=1;
		}
		else {
		    $refersToInstance=1;
		}
	    }
	}
    }
    else {
	# expression indicating an instance
	$typ_clj_sym = $instance_or_type_form;
	$refersToInstance=1;
    }
    if ($refersToType) {
	my $mth;
	($mth, $x) = _peel_critically(\&clojure::core::simple_symbol_QMARK_, $x);
	my $argseq = $x;
	return Pajaro::Salt::callClassMethod($x_cite, $typ_pl, clojure::core::name($mth), map(transpile($opts, $_, $env) , @{clojure::core::_perl_array($argseq)}));
    }
    else {
	# (.-member ob) ====> ${ob}{ member-no-munge }
        # (.method ob arg...) ==> $ob->method (arg...)
	my $mbr;
	($mbr, $x) = _peel_critically(\&clojure::core::simple_symbol_QMARK_, $x);
	my $mbrName = clojure::core::name($mbr);
        if ($mbrName =~ /^-.*/) {
            $mbrName =~ s/^-//;
            Pajaro::Salt::hashMember(transpile($opts, $typ_clj_sym, $env),
                                   Pajaro::Salt::stringLiteral($x_cite, $mbrName))
        }
        else {
            my $perlmbr = munge(clojure::core::name($mbr));
            Pajaro::Salt::callInstanceMethod($x_cite, transpile($opts, $typ_clj_sym, $env), $perlmbr,
map(transpile($opts, $_, $env) , @{clojure::core::_perl_array($x)}))
        }
    }
}

our $LABEL_COUNTER=1;

sub _special_recur {
    my $x0 = shift; # the (recur ...) form
    my $opts = shift;
    my $env = shift; # Perl map of local/let bindings
    die 'Cannot recur from here' unless $$env{'&RECUR-TO'}; # the goto label
    my $x = $x0;
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    # populate @_ with the args of the recur form
    my @loop_value_writers;
    for (my $loop_vals_seq = clojure::core::next(clojure::core::seq($x)); $loop_vals_seq; $loop_vals_seq=&clojure::core::next($loop_vals_seq)) {
        push(@loop_value_writers, transpile($opts, clojure::core::first($loop_vals_seq), $env));
    }
    return Pajaro::Salt::statements($x_cite,
        Pajaro::Salt::statement($x_cite,Pajaro::Salt::assign($x_cite, '@'.'_', Pajaro::Salt::PerlList($x_cite, @loop_value_writers))),
         Pajaro::Salt::goto_($x_cite, $$env{'&RECUR-TO'}));
}

sub _special_if {
    my $x0 = shift; # eg Clojure list indicating a fn call
    my $opts = shift;
    my $env = shift; # Perl map of local/let bindings
    my $x = $x0;
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    my $pw; # PerlWriter
    my $func_arg_terms_seq = clojure::core::rest($x);
    my $condition = clojure::core::first($func_arg_terms_seq);
    $condition = clojure::core::list(clojure::core::symbol('clojure.core','boolean'),$condition);
    $func_arg_terms_seq = clojure::core::rest($func_arg_terms_seq);
    my $action_if_true = clojure::core::first($func_arg_terms_seq);
    ##
    $func_arg_terms_seq = clojure::core::next($func_arg_terms_seq);
    #die("Missing truthy branch:".pr_str($action_if_true)) unless defined($action_if_true);
    # note: when-not gives nil as the truthy branch. Nothing wrong with that

    my $action_if_false = clojure::core::first($func_arg_terms_seq); # optional
    if (!defined($action_if_false)) {
	$action_if_false = undef;
    }
    # if ( CONDITION ) { TRUE-BRANCH } else { FALSE-BRANCH }
    $pw = Pajaro::Salt::ifElsif($x_cite, transpile($opts, $condition, $env),
			      transpile($opts, $action_if_true, $env),
			      transpile($opts, $action_if_false, $env));
		#	$func_arg_terms_seq ? transpile($opts, $action_if_false, $env) : undef);
    return $pw;
}

# Returns a list of Salt Perl-expression composers.
# If nothing is in $body - there is one undef generator returned.
# If 1 thing is in $body - it is transpiled naturally to either expression or statement.
# If >1 thing is in $body - all are transpiled to a statement except the last, which is natural (expression or statement).
sub _transpile_body {
    my $body = shift;
    my $opts = shift;
    my $env = shift; # Perl map of local/let bindings
    my @block_stmts;
    if (0 == clojure::core::count($body)) {
	push(@block_stmts, Pajaro::Salt::verbatimPerl($CITATION_UNAVAILABLE, 'undef'))
    }
    else {
	for(my $body_seq = clojure::core::seq($body); $body_seq; $body_seq = &clojure::core::next($body_seq)) {
	    my $x = clojure::core::first($body_seq);
	    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x);
	    my $hasNext = &clojure::core::next($body_seq);
	    my $stmt = transpile($opts, $x, $env);
	    if ($hasNext) {
		$stmt = Pajaro::Salt::statement($x_cite, $stmt);
	    }
	    push(@block_stmts, $stmt);
	}
    }
    @block_stmts
}

sub _special_let_STAR_ {
    my $x0 = shift; # eg Clojure list: a let form
    my $opts = shift;
    #print STDERR "transpiling special LET: ".pr_str($x)."\n";
    my $env = shift; # Perl map of local/let bindings
    my $x = $x0;
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    my $pw; # PerlWriter
    my $func_arg_terms_seq = clojure::core::rest($x);
    my $binding_vec = clojure::core::first($func_arg_terms_seq);
    die('Vector expected, instead got '.(clojure::core::pr_str($binding_vec))) unless clojure::core::vector_QMARK_($binding_vec);
    my $body = clojure::core::rest($func_arg_terms_seq);
    # prepare new env and prepare to emit it in Perl
    my %env2 = +( %{$env // +{}} );
    my @block_stmts;
    my %declared;
    for(my $binding_seq = clojure::core::seq($binding_vec); $binding_seq; $binding_seq = &clojure::core::next(&clojure::core::rest($binding_seq))) {
        my $k = clojure::core::first($binding_seq);
        my $v = clojure::core::first(clojure::core::rest($binding_seq));
        die "Expected simple symbol, but got ".clojure::core::pr_str($k) unless clojure::core::simple_symbol_QMARK_($k);
        my $kp = munge(clojure::core::name($k));
        my $sigil = '$';
        # important: my $x = $x+1 , refers to the outer scope's x on the RHS
        # use 'my' for the _first_ declaration of each variable per immediate let* form
        my $declAssign;
        if (exists($declared{$kp})) {
            $declAssign = Pajaro::Salt::statement($x_cite, Pajaro::Salt::assign($x_cite, $sigil.$kp, transpile($opts, $v, \%env2)));
        }
        else {
            $declAssign = Pajaro::Salt::declareMy($x_cite, 'my', $sigil.$kp, transpile($opts, $v, \%env2));
            $declared{$kp}=1;
        }
        push(@block_stmts, $declAssign);
        $env2{clojure::core::name($k)}="${sigil}${kp}";
    }
    push(@block_stmts, _transpile_body($body, $opts, \%env2));
    $pw=Pajaro::Salt::block($x_cite, @block_stmts);
    return $pw;
}

# (letfn* [sym1 (fn* ...) sym2 (fn* ...)] body)
sub _special_letfn_STAR_ {
    my $x0 = shift; # eg Clojure list: a letfn* form
    my $opts = shift;
    #print STDERR "transpiling special LETFN: ".pr_str($x)."\n";
    my $env = shift; # Perl map of local/let bindings
    my $x = $x0;
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    my $pw; # PerlWriter
    my $func_arg_terms_seq = clojure::core::rest($x);
    my $binding_vec = clojure::core::first($func_arg_terms_seq);
    die('Vector expected, instead got '.(clojure::core::pr_str($binding_vec))) unless clojure::core::vector_QMARK_($binding_vec);
    my $body = clojure::core::rest($func_arg_terms_seq);
    # prepare new env and prepare to emit it in Perl
    my %env2 = +( %{$env // +{}} );
    my @block_stmts;
    # declare all variables - without initial value:
    for(my $binding_seq = clojure::core::seq($binding_vec); $binding_seq; $binding_seq = &clojure::core::next(&clojure::core::rest($binding_seq))) {
        my $k = clojure::core::first($binding_seq);
        die "Expected simple symbol, but got ".clojure::core::pr_str($k) unless clojure::core::simple_symbol_QMARK_($k);
        my $kp = munge(clojure::core::name($k));
        my $sigil = '$';
        push(@block_stmts, Pajaro::Salt::declareMy($x_cite, 'my', $sigil.$kp));
        $env2{clojure::core::name($k)}="${sigil}${kp}";
    }
    # assign values:
    for(my $binding_seq = clojure::core::seq($binding_vec); $binding_seq; $binding_seq = &clojure::core::next(&clojure::core::rest($binding_seq))) {
        my $k = clojure::core::first($binding_seq);
        my $v = clojure::core::first(clojure::core::rest($binding_seq));
        die "Expected simple symbol, but got ".clojure::core::pr_str($k) unless clojure::core::simple_symbol_QMARK_($k);
        my $kp = munge(clojure::core::name($k));
        my $sigil = '$';
        push(@block_stmts, Pajaro::Salt::statement($x_cite,Pajaro::Salt::assign($x_cite, $sigil.$kp, transpile($opts, $v, \%env2))));
    }
    for(my $body_seq = clojure::core::seq($body); $body_seq; $body_seq = &clojure::core::next($body_seq)) {
        my $x = clojure::core::first($body_seq);
        push(@block_stmts, transpile($opts, $x, \%env2));
    }
    $pw=Pajaro::Salt::block($x_cite, @block_stmts);
    return $pw;
}

sub _special_loop {
    my $x0 = shift; # (loop ...)
    my $opts = shift;
    #print STDERR "transpiling LOOP: ".pr_str($x)."\n";
    my $env = shift; # Perl map of local/let bindings
    my $x = $x0;
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    my $pw; # PerlWriter
    my $func_arg_terms_seq = clojure::core::rest($x); # [...], body-of-loop
    my $binding_vec = clojure::core::first($func_arg_terms_seq);
    die('Vector expected') unless clojure::core::vector_QMARK_($binding_vec);
    my $body = clojure::core::rest($func_arg_terms_seq);
    # prepare new env and prepare to emit it in Perl
    my %env2 = +( %{$env // +{}} );
    my @declarations;
    my @initial_values;
    # compose loop-variable declarations and collect the initial values
    for(my $binding_seq = clojure::core::seq($binding_vec); $binding_seq; $binding_seq = &clojure::core::next(&clojure::core::rest($binding_seq))) {
        my $k = clojure::core::first($binding_seq);
        my $v = clojure::core::first(clojure::core::rest($binding_seq));
        die unless clojure::core::simple_symbol_QMARK_($k);
        my $kp = munge(clojure::core::name($k));
        my $sigil = '$';
        push(@declarations, Pajaro::Salt::declareMy($x_cite, 'my', "${sigil}${kp}"));
        push(@initial_values, transpile($opts, $v, \%env2));
        $env2{clojure::core::name($k)}="${sigil}${kp}";
    }
    my @block_stmts;
    # put initial values into @_ *before* possibly shadowing their source variables with loop-scoped variables
    push(@block_stmts, Pajaro::Salt::statement($x_cite, Pajaro::Salt::assign($x_cite, '@'.'_', Pajaro::Salt::PerlList($x_cite, @initial_values))));
    push(@block_stmts, @declarations);
    # 'recur' will resume at this point:
    my $label='T'.++$LABEL_COUNTER;
    push(@block_stmts, Pajaro::Salt::label($x_cite, $label)); ## AT THIS POINT, @_ SHOULD CONTAIN individual values to bind to loop variables
    my $memo = clojure::core::pr_str($binding_vec);
    my $n_bindings = clojure::core::count($binding_vec) / 2;
    push(@block_stmts, Pajaro::Salt::statement($CITATION_UNAVAILABLE, "if($n_bindings!=\@_){die(q(Expected $n_bindings values to bind to $memo, but received ).(0+\@_).qq( at label $label))}"));
    $env2{'&RECUR-TO'}=$label;
    # unpack @_ to local variables
    for(my $binding_seq = clojure::core::seq($binding_vec); $binding_seq; $binding_seq = &clojure::core::next(&clojure::core::rest($binding_seq))) {
        my $k = clojure::core::first($binding_seq);
        my $v = clojure::core::first(clojure::core::rest($binding_seq));
        die unless clojure::core::simple_symbol_QMARK_($k);
        my $kp = munge(clojure::core::name($k));
        my $sigil = '$';
        push(@block_stmts, Pajaro::Salt::statement($x_cite, Pajaro::Salt::assign($x_cite, $sigil.$kp, Pajaro::Salt::rawExpression($x_cite, 'shift(@_)'))));
    }
    push(@block_stmts, _transpile_body($body, $opts, \%env2));
    $pw=Pajaro::Salt::block($x_cite, @block_stmts);
    return $pw;
}

sub _special_do {
    my $x0 = shift; # (do ...)
    my $opts = shift;
    my $env = shift;
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    my $x = $x0;
    my $func_arg_terms_seq = &clojure::core::next($x);
    my $body = $func_arg_terms_seq;
    my @block_stmts = _transpile_body($body, $opts, $env);
    if (1 == @block_stmts) {
	$block_stmts[0]
    }
    else {
	Pajaro::Salt::block($x_cite, @block_stmts);
    }
}

sub _special_def {
    my $x0 = shift; # eg Clojure list of 'def'/'defonce'/'set!', symbol, stuff
    my $opts = shift;
    my $env = shift; # Perl map of local/let bindings
    #print STDERR "transpiling: ".pr_str($x)."\n";
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    my $x = $x0;
    my $pw; # PerlWriter
    my $func_term; # def, defonce, set!
    ($func_term, $x) = _peel_critically(\&clojure::core::simple_symbol_QMARK_, $x);
    my $symbol;
    ($symbol, $x) = _peel_critically(\&clojure::core::simple_symbol_QMARK_, $x);
    my ($symbol_cite, $symbol_user_meta) = Pajaro::_citation_and_user_meta($symbol);
    #$symbol_user_meta =
    #    ($symbol_user_meta || clojure::core::hash_map())
    #    ->assoc($Pajaro::KW_FILE, $$symbol_cite[1],
    #            $Pajaro::KW_LINE, $$symbol_cite[0]);
    my $has_init = clojure::core::boolean(clojure::core::seq($x));
    my $docstring;
    ($docstring, $x) = _peel_selectively(\&clojure::core::string_QMARK_, $x);
    my $init;
    if (clojure::core::seq($x)) {
	$init = clojure::core::first($x);
	$x = clojure::core::rest($x);
    }
    else {
	$init = $docstring;
	undef $docstring;
    }
    # _intern1( NAMESPACE-NAME, NAME-META, NAME-NAME [, VALUE] )
    my $ns_name=clojure::core::name(clojure::core::ns_name(clojure::core::deref($clojure::core::_STAR_ns_STAR_)));
    my $sym_name=clojure::core::name($symbol);
    if ($has_init) {
        #print STDERR "Interning before compiling init value or meta: $sym_name\n";
        Pajaro::_intern1($ns_name, clojure::core::hash_map(), $sym_name); # so (def x x) works
        Pajaro::Salt::callFunction
            ($x_cite, 'Pajaro::_intern1',
             Pajaro::Salt::stringLiteral($x_cite, $ns_name),
             transpile($opts, $symbol_user_meta),
             Pajaro::Salt::stringLiteral($x_cite, $sym_name),
             transpile($opts, $init))
    }
    else {
        Pajaro::Salt::callFunction
            ($x_cite, 'Pajaro::_intern1',
             Pajaro::Salt::stringLiteral($x_cite, $ns_name),
             transpile($opts, $symbol_user_meta),
             Pajaro::Salt::stringLiteral($x_cite, $sym_name))
    }
}

sub _special_set_BANG_ {
    my $x0 = shift; # eg Clojure list of 'def'/'defonce'/'set!', symbol, stuff
    my $opts = shift;
    my $env = shift; # Perl map of local/let bindings
    #print STDERR "transpiling: ".pr_str($x)."\n";
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    my $x = $x0;
    my $pw; # PerlWriter
    my $func_term; # def, defonce, set!
    ($func_term, $x) = _peel_critically(\&clojure::core::simple_symbol_QMARK_, $x);
    my $symbol;
    ($symbol, $x) = _peel_critically(\&clojure::core::symbol_QMARK_, $x);
    my ($symbol_cite, $symbol_user_meta) = Pajaro::_citation_and_user_meta($symbol);
    my $init;
    $init = clojure::core::first($x);

    #  (set! x 42) ... where x is a dynamic member of a type
    my $is_simple_symbol=clojure::core::simple_symbol_QMARK_($symbol);
    my $symbol_name=clojure::core::name($symbol);
    my $env_entry=(exists($$env{$symbol_name}) && $$env{$symbol_name});
    if ($is_simple_symbol && $env_entry && ($env_entry =~ /\$\$[a-zA-Z_0-9]+[{].*[}]/)) {
	#print STDERR "set!: in local env: $symbol_name ===> $env_entry \n";
	return Pajaro::Salt::statement($symbol_cite,Pajaro::Salt::assign($symbol_cite, $env_entry, transpile($opts, $init, $env)));
    }


    # resolve the symbol, which might be simple or qualiified
    # check that it exists and has :dynamic metadata
    my $qual = clojure::core::simple_symbol_QMARK_($symbol)
        ? clojure::core::symbol(clojure::core::name(clojure::core::ns_name(clojure::core::deref($clojure::core::_STAR_ns_STAR_))), clojure::core::name($symbol))
        : $symbol;
    my $var = clojure::core::find_var($qual);
    if (!$var) {
        die("No such var: ".clojure::core::pr_str($symbol). " (qualified as ".clojure::core::pr_str($qual).")");
    }
    my $varmeta = clojure::core::meta($var);
    die 'Not dynamic:'.clojure::core::pr_str($var)." (meta:".clojure::core::pr_str($varmeta) unless clojure::core::get($varmeta, $Pajaro::KW_DYNAMIC);
    my $plOfVar = Pajaro::Salt::rawExpression
	($x_cite,
	'$'.Pajaro::_namespace_munge(clojure::core::namespace($qual)).'::'.munge(clojure::core::name($qual))); ##transpile($opts, $qual, $env), also derefs. Don't do that
    Pajaro::Salt::statement
	($x_cite,
	 Pajaro::Salt::callFunction
	 ($x_cite, 'clojure::core::_set_root_binding_BANG_',
	  $plOfVar,
	  transpile($opts, $init, $env)));
    # should return the new value
}

sub _special_binding_STAR_ {
    my $x0 = shift; # eg Clojure list: a binding form
    my $opts = shift;
    #print STDERR "transpiling special BINDING: ".pr_str($x)."\n";
    my $env = shift; # Perl map of local/let bindings
    my $x = $x0;
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    my $pw; # PerlWriter
    my $func_arg_terms_seq = clojure::core::rest($x);
    my $binding_vec = clojure::core::first($func_arg_terms_seq);
    die('Vector expected, instead got '.(clojure::core::pr_str($binding_vec))) unless clojure::core::vector_QMARK_($binding_vec);
    my $body = clojure::core::rest($func_arg_terms_seq);
    # prepare new env and prepare to emit it in Perl
    #my %env2 = +( %{$env // +{}} );
    my @block_stmts;
    my %declared;
    for(my $binding_seq = clojure::core::seq($binding_vec); $binding_seq; $binding_seq = &clojure::core::next(&clojure::core::rest($binding_seq))) {
        my $symbol = clojure::core::first($binding_seq);
        my $v = clojure::core::first(clojure::core::rest($binding_seq));
        die "Expected symbol, but got ".clojure::core::pr_str($symbol) unless clojure::core::symbol_QMARK_($symbol);

        # resolve the symbol, which might be simple or qualiified
        # check that it exists and has :dynamic metadata
        my $qual = clojure::core::simple_symbol_QMARK_($symbol)
            ? clojure::core::symbol(clojure::core::name(clojure::core::ns_name(clojure::core::deref($clojure::core::_STAR_ns_STAR_))), clojure::core::name($symbol))
            : $symbol;
        my $var = clojure::core::find_var($qual);
        if (!$var) {
            die("No such var: ".clojure::core::pr_str($symbol). " (qualified as ".clojure::core::pr_str($qual).")");
        }
        my $varmeta = clojure::core::meta($var);
        die 'Not dynamic:'.clojure::core::pr_str($var)." (meta:".clojure::core::pr_str($varmeta) unless clojure::core::get($varmeta, $Pajaro::KW_DYNAMIC);
        my $plOfVar = Pajaro::Salt::rawExpression
            ($x_cite,
             '$'.Pajaro::_namespace_munge(clojure::core::namespace($qual)).'::'.munge(clojure::core::name($qual))); ##transpile($opts, $qual, $env), also derefs. Don't do that
	my $plOfVarDynamicFlag = Pajaro::Salt::arrayMember($plOfVar, Pajaro::Var::VAR_DYNAMIC_SET_SLOT);
	my $declAssign1 = Pajaro::Salt::declareMy($x_cite, 'local', $plOfVarDynamicFlag, transpile($opts, '1', $env));
        my $plOfVarPayload = Pajaro::Salt::arrayMember($plOfVar, Pajaro::Var::VAR_DYNAMIC_REFERENT_SLOT);
        my $declAssign2 = Pajaro::Salt::declareMy($x_cite, 'local', $plOfVarPayload, transpile($opts, $v, $env));
        push(@block_stmts, $declAssign1, $declAssign2);
    }
    push(@block_stmts, _transpile_body($body, $opts, $env));
    $pw=Pajaro::Salt::block($x_cite, @block_stmts);
    return $pw;
}

sub _special_perl_infix {
    my $x0 = shift; # Clojure list (perl-infix "+" a b...)
    my $opts = shift;
    my $env = shift;
    my $x = $x0;
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    $x = clojure::core::rest($x); # discard 'perl-infix
    my $operator;
    ($operator, $x) = _peel_critically(\&clojure::core::string_QMARK_, $x);
    my $perl_list = clojure::core::_perl_array($x);
    my @pws = map(transpile($opts, $_, $env), @{$perl_list});
    Pajaro::Salt::infix(Pajaro::Salt::rawExpression($x_cite, "$operator"), @pws)
}

sub _special_perl_unary {
    my $x0 = shift; # Clojure list (perl-unary "~" a)
    my $opts = shift;
    my $env = shift;
    my $x = $x0;
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    $x = clojure::core::rest($x); # discard 'perl-unary
    my $operator;
    ($operator, $x) = _peel_critically(\&clojure::core::string_QMARK_, $x);
    my $n = clojure::core::first($x);
    my $nx = transpile($opts, $n, $env);
    Pajaro::Salt::unary($operator, Pajaro::Salt::rawExpression($x_cite, $nx));
}

sub _special_try {
    my $x0 = shift; # Clojure list (try ...
    my $opts = shift;
    my $env = shift;
    my $x = $x0;
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    $x = clojure::core::rest($x); # discard 'try
    # (try EXPRS CATCH-CLAUSE ...
    #    ...where CATCH-CLAUSE is:  (catch TYPE-OR-:default SYMBOL EXPRS)
    # {
    #   my $exc#;
    #   my $ret#;
    #   {
    #    local $@;
    #    $ret# = eval { ... };
    #    if ($@) {
    #      my ... = $@

    #      (:default only)
    #      ...

    #      (specified exception types the last of which might be :default)
    #      my $t# = name(type(...))
    #      if ($t# eq ...) {
    #              ^^-- the condition is one of:
    #                (a) Protocol:   satisfies?(PROTO, EXC.OBJECT)
    #                (b) Type:       instance?(TYPE, EXC.OBJECT)
    #         ...
    #      } elsif ... ... ...
    #      else {
    #        (if :default, it's here. Otherwise re-throw the exception)
    #        $exc# = ...
    #      }

    #    }
    #   }
    #   if ($exc#) {die $exc#} else { $ret# }
    # }
    my @body;
    my @catches; # excl default
    my $finally;
    my $finally_cite;
    my $default_catch;
    for (my $s = clojure::core::seq($x); $s; $s=clojure::core::next($s)) {
	my $t = clojure::core::first($s);
	my $isCatch;
        my $isFinally;
	if (clojure::core::seq_QMARK_($t)) {
	    my $t1 = clojure::core::first($t);
	    if (clojure::core::simple_symbol_QMARK_($t1)) {
		if ('catch' eq clojure::core::name($t1)) {
		    $isCatch = 1;
		}
		elsif ('finally' eq clojure::core::name($t1)) {
		    $isFinally = 1;
                    ($finally_cite, my $finally_user_meta) = Pajaro::_citation_and_user_meta($t1);
		}
	    }
	}
	if ($isCatch) {
	    my $tr = clojure::core::rest($t);
	    my $ec = clojure::core::first($tr); # exception class
	    my $trr = clojure::core::rest($tr);
	    my $ev = clojure::core::first($trr); # exception variable
	    die(":default expected as type of thing to catch") unless
		clojure::core::simple_keyword_QMARK_($ec)
		&& 'default' eq clojure::core::name($ec);
	    die("simple symbol expected") unless
		clojure::core::simple_symbol_QMARK_($ev);
	    my $catchbodyseq = clojure::core::rest($trr);
	    my $clause = +{'clause'=>$t,
			       'type'=>$ec,
			       'binding'=>$ev,
			       'body-seq'=>$catchbodyseq};
	    $default_catch = $clause;
	}
        elsif ($isFinally) {
            $finally= clojure::core::rest($t);
        }
	else {
	    push(@body, $t);
	}
    }
    if (!$default_catch && !@catches && !$finally) {
	die "try with neither catch nor finally";
    }
    if (!$default_catch) {
        $default_catch = +{'clause'=>clojure::core::symbol('nil'),
			       'type'=>clojure::core::keyword('default'),
			       'binding'=>clojure::core::symbol('x'),
			       'body-seq'=>clojure::core::list(clojure::core::list(clojure::core::symbol('throw'),clojure::core::symbol('x')))};
    }
    my $exc_local = '$'.clojure::core::genlocal('try_err');
    my $ret_local = '$'.clojure::core::genlocal('try_ret');

    Pajaro::Salt::block
	($x_cite,
	 #Pajaro::Salt::declareMy($x_cite, 'my', $exc_local), <== you'll need this when accommodating exception-type cases
	 Pajaro::Salt::declareMy($x_cite, 'my', $ret_local),
	 Pajaro::Salt::block
	 ($x_cite,
	  Pajaro::Salt::statement
	  ($x_cite,
	   Pajaro::Salt::verbatimPerl($x_cite, 'local$@')
	  ),

	  Pajaro::Salt::statement
	  ($x_cite,
	   Pajaro::Salt::assign
	   ($x_cite,
	    Pajaro::Salt::verbatimPerl($x_cite, $ret_local),
	    Pajaro::Salt::evalBlock
	    ($x_cite,
	     map(Pajaro::Salt::statement($x_cite, $_),
		 map(transpile($opts, $_, $env), @body))))),

          $finally ?
          Pajaro::Salt::block($finally_cite || $CITATION_UNAVAILABLE,
                            Pajaro::Salt::statement($finally_cite || $CITATION_UNAVAILABLE,
                                                  Pajaro::Salt::declareMy($finally_cite || $CITATION_UNAVAILABLE,
                                                                        'local', '$@')),
                            Pajaro::Salt::statement($finally_cite || $CITATION_UNAVAILABLE,
                                                  transpile($opts,
                                                            clojure::core::cons(clojure::core::symbol('do'),
                                                                       $finally), $env)))
          :undef,

	  Pajaro::Salt::ifElsif
	  ($x_cite,
	   Pajaro::Salt::verbatimPerl($x_cite, '$@'),
	   Pajaro::Salt::block
	   ($x_cite,
	    #Pajaro::Salt::statement <== you'll need this when accommodating exception-type cases
	    #($x_cite,
	    # Pajaro::Salt::assign
	    # ($x_cite,
	    #  Pajaro::Salt::verbatimPerl($x_cite, $exc_local),
	    #  Pajaro::Salt::verbatimPerl($x_cite, '$@'))),
	    Pajaro::Salt::statement
	    ($x_cite,
	     Pajaro::Salt::declareMy
	     ($x_cite,
	      'my',
	      Pajaro::Salt::verbatimPerl
	      ($x_cite, '$'.munge(clojure::core::name($$default_catch{'binding'}))),
	      Pajaro::Salt::verbatimPerl($x_cite, '$@'))),
	    Pajaro::Salt::statement
	    ($x_cite,
	     Pajaro::Salt::assign
	     ($x_cite,
	      Pajaro::Salt::verbatimPerl($x_cite, $ret_local),
	      transpile($opts,
			clojure::core::conj($$default_catch{'body-seq'},
				   clojure::core::symbol('do')),
			&{sub{my $oldenv=shift;
			      my $cljvarname=shift;
			      my $perlvarname=shift;
			      my %e2 = %$oldenv;
			      $e2{$cljvarname}=$perlvarname;
			      \%e2}}($env,
				     clojure::core::name($$default_catch{'binding'}),
				     '$'.munge(clojure::core::name($$default_catch{'binding'}))))))))),
	 Pajaro::Salt::rawExpression($x_cite, $ret_local)
	 #Pajaro::Salt::statement <== you'll need this when accommodating exception-type cases
	 #($x_cite,
	 # "if ($exc_local) {die $exc_local} else { $ret_local }")
	);
}

sub _special_throw {
    my $x0 = shift; # Clojure list (throw x)
    my $opts = shift;
    my $env = shift;
    my $x = $x0;
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    $x = clojure::core::first(clojure::core::rest($x));
    my ($x1_cite, $x1_user_meta) = Pajaro::_citation_and_user_meta($x);
    my $cite = $x1_cite || $x_cite;
    # Add ||"No message" so that if($@){...} may be certain to fire
    Pajaro::Salt::statement
        ($cite,
         Pajaro::Salt::verbatimPerl($cite, 'die'),
         Pajaro::Salt::wrapParens
         ($cite,
          Pajaro::Salt::wrapParens
          ($cite,
           transpile($opts, $x, $env)),
          Pajaro::Salt::verbatimPerl($cite,'||"No message"')));
}

# deftype* has an option:  :constructor STRING   which overrides the pkg fn name of "new"
sub _special_deftype_STAR_ { # special form because of lack of destructuring
    my $x0 = shift; # Clojure list (deftype* ...
    my $opts = shift;
    my $env = shift;
    my $x = $x0;
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x0);
    $x = &clojure::core::next($x); # discard 'deftype*
    my $type_symbol;
    ($type_symbol, $x) = _peel_critically(\&clojure::core::simple_symbol_QMARK_, $x);
    my ($type_symbol_cite, $type_symbol_user_meta) = Pajaro::_citation_and_user_meta($type_symbol);
    my $ctor_name = 'new'; # default
    # consume options:
    for (;;) {
	my $opt;
	($opt, $x) = _peel_selectively(\&clojure::core::keyword_QMARK_, $x);
	if ($opt) {
	    my $v = &clojure::core::first($x); # option value
	    my $optname = &clojure::core::name($opt);
	    if ($optname eq 'constructor') {
		$ctor_name = &clojure::core::name($v);
	    }
	    $x = &clojure::core::next($x);  # discard option value
	}
	else {
	    last;
	}
    }
    my $perlTypeSimple=munge(&clojure::core::name($type_symbol));
    my $full_type_clj = &clojure::core::name(&clojure::core::ns_name(clojure::core::deref($clojure::core::_STAR_ns_STAR_))).'.'.&clojure::core::name($type_symbol);
    my $type_pl = Pajaro::_namespace_munge($full_type_clj);
    my $member_vec;
    ($member_vec, $x) = _peel_critically(\&clojure::core::vector_QMARK_, $x);
    my @protocols;
    my @methods;
    my @satisfiesStmts;
    for (my $ix = &clojure::core::seq($x); $ix; $ix=&clojure::core::next($ix)) {
	my $t = &clojure::core::first($ix);
	if (clojure::core::simple_symbol_QMARK_($t)) {
            my ($proto_cite, $proto_user_meta) = Pajaro::_citation_and_user_meta($t);
	    # if it does not include '.' then assume *ns*
	    my $n = clojure::core::name($t);
	    if ($n !~ /[.]/) {
		$t = clojure::core::symbol(clojure::core::name(clojure::core::ns_name(clojure::core::deref($clojure::core::_STAR_ns_STAR_))).'.'.$n);
	    }
	    push(@protocols, $t);
            # Indicate satisfaction of protocol
            my $protocolPkgPerl = Pajaro::_namespace_munge($t->name());
            # The protocol name's own package-global scalar may hold either
            # the bare Protocol object, or (see _setup_protocol) a Var
            # referring to one; unwrap the latter. Read the scalar itself
            # (not %TYPES, which _find_type_backfill would consult) so a
            # protocol redefined via a second (defprotocol ...) is resolved
            # to its current, not its original, Protocol object.
            my $protocolLookup = Pajaro::Salt::callFunction
                ($proto_cite, 'Pajaro::_deref_if_var',
                 Pajaro::Salt::verbatimPerl($proto_cite, '$'.$protocolPkgPerl));
            push (@satisfiesStmts, Pajaro::Salt::statement
                  ($proto_cite,
                   Pajaro::Salt::hashMember(Pajaro::Salt::arrayMember($protocolLookup, Pajaro::Protocol::APROTOCOL_EXTENSIONS), Pajaro::Salt::stringLiteral($proto_cite, $full_type_clj)),
                   '=', '1'));
	}
	elsif (clojure::core::seq_QMARK_($t)) {
	    push(@methods, $t);
	}
	else {
	    die "What is (neither seq nor simple symbol) ".$t;
	}
    }
    my @stmts;
    # package statement
    push (@stmts, Pajaro::Salt::statement($type_symbol_cite, 'package ' . $type_pl));
    # empty @ISA
    push (@stmts, Pajaro::Salt::declareMy($x_cite, 'our', '@ISA', Pajaro::Salt::PerlList($x_cite)));
    # sub new { my $class=shift; my $self=+{...}; return bless $self, $class; }
    my @ctorBodyShiftAssignments =
        (Pajaro::Salt::declareMy($type_symbol_cite, 'my', '$self', Pajaro::Salt::verbatimPerl($type_symbol_cite,'+{}')),
         map(Pajaro::Salt::statement($type_symbol_cite, '$$self{qq('.&clojure::core::name($_).')}=shift'), @{clojure::core::_perl_array($member_vec)}));
    push (@stmts,
	Pajaro::Salt::perlSub
	($type_symbol_cite, $ctor_name,
	 Pajaro::Salt::statements($type_symbol_cite,
                                Pajaro::Salt::declareMy($type_symbol_cite, 'my', '$class', Pajaro::Salt::verbatimPerl($type_symbol_cite,'shift')),
				@ctorBodyShiftAssignments,
				Pajaro::Salt::statement($type_symbol_cite, 'return bless $self, $class'))));
    # methods - with only the type's members in closure
    for my $method (@methods) {
	my $methodName = clojure::core::first($method);
	die unless clojure::core::simple_symbol_QMARK_($methodName);
	my ($methodName_cite, $methodName_user_meta) = Pajaro::_citation_and_user_meta($methodName);
	my $argVec = clojure::core::second($method);
	die unless clojure::core::vector_QMARK_($argVec);
	my $thisArg = clojure::core::first($argVec);
	die unless clojure::core::simple_symbol_QMARK_($thisArg);
        my %env2;
        for (my $ix = &clojure::core::seq($member_vec); $ix; $ix=&clojure::core::next($ix)) {
            my $t = &clojure::core::first($ix);
            if (clojure::core::simple_symbol_QMARK_($t)) {
                my $memberPerl = '$$'.munge(&clojure::core::name($thisArg)).'{qq('.&clojure::core::name($t).')}';
                $env2{&clojure::core::name($t)} = $memberPerl;
            }
            else {
                die "What is member ".$t;
            }
        }
	my $method_tail_salt = _transpile_single_arity_fn_tail_statements($opts, clojure::core::rest($method), \%env2);
	push(@stmts, Pajaro::Salt::perlSub($methodName_cite,
					 munge(&clojure::core::str(&clojure::core::name($methodName))),
					 $method_tail_salt));
        if ('-code' eq clojure::core::name($methodName)) {
            # CODE cast:
	    # The &{} override receives all the call parameters! But IFn's code method takes only one.
            push(@stmts, Pajaro::Salt::statement($methodName_cite, q(use overload '&{}' => sub{&_code($_[0])}, 'fallback' => 1)));
        }
    }
    # let's move the ctor fn to a macro
    my $internTypeSalt = Pajaro::Salt::statement($x_cite, Pajaro::Salt::callFunction($x_cite, 'Pajaro::_intern_type', Pajaro::Salt::stringLiteral($x_cite,$full_type_clj)));
    my $globalHierarchyUpdateSalt = Pajaro::Salt::statement($x_cite, Pajaro::Salt::callFunction($x_cite, 'Pajaro::_freshen_global_hierarchy'));
    my $quote_opts = +{%{$opts}};
    $$quote_opts{'QUOTE'}=6418;
    return Pajaro::Salt::statements
	($x_cite,
	 Pajaro::Salt::block($x_cite, @stmts),
         @satisfiesStmts,
	 $internTypeSalt,
	 $globalHierarchyUpdateSalt,
	 # return value:
	 transpile($quote_opts, clojure::core::symbol($full_type_clj), $env));
}

sub wrapWithMetaOf {
    my $salt = shift;
    my $objectWithMeta = shift;
    my $opts = shift;
    my $m = clojure::core::meta($objectWithMeta);
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($objectWithMeta);
    if (clojure::core::seq($x_user_meta)) {
        Pajaro::Salt::callFunction
            ($x_cite,
             'clojure::core::with_meta',
             $salt,
             transpile($opts, $x_user_meta))
    }
    else {
        $salt
    }
}

Pajaro::_extend_type
    (Pajaro::_find_type_or_die(''),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift;
           my $opts = shift;
           my $env = shift;
           Pajaro::Salt::rawExpression($CITATION_UNAVAILABLE, 'undef')
       }});

Pajaro::_extend_type
    (Pajaro::_intern_type('Pajaro.Double'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift;
           my $opts = shift;
           my $env = shift;
	   if ($x != $x) {
	       Pajaro::Salt::rawExpression($CITATION_UNAVAILABLE, 'builtin::nan()')
	   }
	   elsif ($x == builtin::inf()) {
	       Pajaro::Salt::rawExpression($CITATION_UNAVAILABLE, 'builtin::inf()')
	   }
	   elsif ($x == -builtin::inf()) {
	       Pajaro::Salt::rawExpression($CITATION_UNAVAILABLE, '-builtin::inf()')
	   }
	   else {
	       Pajaro::Salt::rawExpression($CITATION_UNAVAILABLE, Pajaro::Double::_perl_float_literal($x))
	   }
       }});
Pajaro::_extend_type
    (Pajaro::_intern_type('Pajaro.Long'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift;
           my $opts = shift;
           my $env = shift;
	   Pajaro::Salt::rawExpression($CITATION_UNAVAILABLE, "$x")
       }});
Pajaro::_extend_type
    (Pajaro::_intern_type('Math.BigInt'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift;
           my $opts = shift;
           my $env = shift;
	   #if ($x != $x) {
	   #    Pajaro::Salt::rawExpression($CITATION_UNAVAILABLE, 'Math::BigInt->bnan()')
	   #}
	   #elsif ($x == builtin::inf()) {
	   #    Pajaro::Salt::rawExpression($CITATION_UNAVAILABLE, 'Math::BigInt->binf(q(+))')
	   #}
	   #elsif ($x == -builtin::inf()) {
	   #    Pajaro::Salt::rawExpression($CITATION_UNAVAILABLE, 'Math::BigInt->binf(q(-))')
	   #}
	   #else {
	       Pajaro::Salt::callClassMethod
		   ($CITATION_UNAVAILABLE,
		    'Math::BigInt',
		    'new',
		    Pajaro::Salt::stringLiteral($CITATION_UNAVAILABLE, "$x"))
	   #}
       }});
Pajaro::_extend_type
    (Pajaro::_intern_type('Math.BigFloat'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift;
           my $opts = shift;
           my $env = shift;
	   #if ($x != $x) {
	   #    Pajaro::Salt::rawExpression($CITATION_UNAVAILABLE, 'builtin::nan()')
	   #}
	   #elsif ($x == builtin::inf()) {
	   #    Pajaro::Salt::rawExpression($CITATION_UNAVAILABLE, 'builtin::inf()')
	   #}
	   #elsif ($x == -builtin::inf()) {
	   #    Pajaro::Salt::rawExpression($CITATION_UNAVAILABLE, '-builtin::inf()')
	   #}
	   #else {
	   
	   #A    Pajaro::Salt::callInstanceMethod
		#   ($CITATION_UNAVAILABLE,
		#    Pajaro::Salt::callClassMethod
		#    ($CITATION_UNAVAILABLE,
		#     'Math::BigFloat',
		#     'new',
		#     Pajaro::Salt::stringLiteral($CITATION_UNAVAILABLE, "$x")),
		#    'bfround',
		#    Pajaro::Salt::rawExpression
		#    ($CITATION_UNAVAILABLE,
		#     $x->precision()));

		   Pajaro::Salt::callClassMethod
		    ($CITATION_UNAVAILABLE,
		     'Math::BigFloat',
		     'new',
		     Pajaro::Salt::stringLiteral($CITATION_UNAVAILABLE, "$x"))
	   #}
       }});
Pajaro::_extend_type
    (Pajaro::_intern_type('Math.BigRat'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift;
           my $opts = shift;
           my $env = shift;
           #if ($x != $x) {
           #    Pajaro::Salt::rawExpression($CITATION_UNAVAILABLE, 'builtin::nan()')
           #}
           #elsif ($x == builtin::inf()) {
           #    Pajaro::Salt::rawExpression($CITATION_UNAVAILABLE, 'builtin::inf()')
           #}
           #elsif ($x == -builtin::inf()) {
           #    Pajaro::Salt::rawExpression($CITATION_UNAVAILABLE, '-builtin::inf()')
           #}
           #else {
               Pajaro::Salt::callClassMethod
                   ($CITATION_UNAVAILABLE,
                    'Math::BigRat',
                    'new',
                    transpile($opts, $x->numerator(), $env),
                    transpile($opts, $x->denominator(), $env))
           #}
       }});

Pajaro::_extend_type
    (Pajaro::_intern_type('Pajaro.String'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift;
           my $opts = shift;
           my $env = shift;
           Pajaro::Salt::stringLiteral($CITATION_UNAVAILABLE, $x)
       }});
Pajaro::_extend_type
    (Pajaro::_intern_type('Pajaro.Boolean'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift;
           my $opts = shift;
           my $env = shift;
           Pajaro::Salt::rawExpression
               ($CITATION_UNAVAILABLE,
                $x ? 'builtin::true' : 'builtin::false')
       }});
Pajaro::_extend_type
    (Pajaro::_intern_type('Pajaro.AMap'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift;
           my $opts = shift;
           my $env = shift;
           my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x);
	   my $s = clojure::core::seq($x);
	   my $salt;
	   if (!defined($s)) {
               $salt=Pajaro::Salt::verbatimPerl($x_cite, '$Pajaro::COWMap::EMPTY');
           }
	   else {
	       my @args;
	       for (; $s; $s=&clojure::core::next($s)) {
		   my $e = clojure::core::first($s);
		   my $k = clojure::core::key($e);
		   my $v = clojure::core::val($e);
		   push(@args, transpile($opts, $k, $env));
		   push(@args, transpile($opts, $v, $env));
	       }
	       $salt=Pajaro::Salt::callFunction($x_cite, 'clojure::core::hash_map', @args)
	   }
	   wrapWithMetaOf($salt, $x, $opts);
       }});
Pajaro::_extend_type
    (Pajaro::_intern_type('Pajaro.AVector'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift;
           my $opts = shift;
           my $env = shift;
	   my $salt;
	   my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x);
           my $s = clojure::core::seq($x);
           if (!defined($s)) {
               $salt = Pajaro::Salt::verbatimPerl($x_cite, '$Pajaro::COWVector::EMPTY');
           }
           else {
               my @args;
               do {
                   push(@args, transpile($opts, clojure::core::first($s), $env));
               } while ($s=&clojure::core::next($s));
               $salt = Pajaro::Salt::callFunction($x_cite, 'clojure::core::vector', @args);
           }
	   wrapWithMetaOf($salt, $x, $opts);
       }});
Pajaro::_extend_type
    (Pajaro::_intern_type('Pajaro.ASet'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift;
           my $opts = shift;
           my $env = shift;
           my $salt;
	   my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x);
           my $s = clojure::core::seq($x);
           if (!defined($s)) {
               $salt = Pajaro::Salt::verbatimPerl($x_cite, '$Pajaro::COWSet::EMPTY');
           }
           else {
               my @args;
               do {
                   push(@args, transpile($opts, clojure::core::first($s), $env));
               } while ($s=&clojure::core::next($s));
               $salt = Pajaro::Salt::callFunction($x_cite, 'clojure::core::hash_set', @args);
           }
	   wrapWithMetaOf($salt, $x, $opts);
       }});

sub _transpile_single_arity_fn_tail_statements { # arglist and body; returns (Salt 'statements' to go inside a sub{... block, min-args, max-args)
    my $opts = shift;
    my $token_seq = shift; # arglist or multi-arity list
    my $env = shift;
    my $s = $token_seq;
    (my $arglist_vec, $s) = _peel_critically(\&clojure::core::vector_QMARK_, $s);
    my $body = $s;
    my %env2 = +( %{$env // +{}} );

    my $pw;
    my @block_stmts;
    my $min_args=0;
    my $max_args=0;
    my $vararg = ((clojure::core::count($arglist_vec)>1)
                  && clojure::core::_equiv(clojure::core::symbol('&'),
                                  clojure::core::nth($arglist_vec,
                                            clojure::core::count($arglist_vec)-2)));
    if ($vararg) {
        my $n_individual_args = clojure::core::count($arglist_vec)-2;
        # Gather the etc args into a List to bind to a single variable
        push(@block_stmts,
             Pajaro::Salt::statement
             ($CITATION_UNAVAILABLE,
	      ## If last thing in @_ has meta :apply-splat, then strip that meta and use list* instead of list
	      "if(\@_<$n_individual_args){die(q(Expected $n_individual_args but got fewer args:).join(q(,),map(clojure::core::pr_str(\$_),\@_)))}else{
my\$lf;
my\$splat=clojure::core::get(clojure::core::meta(\$_[\$#_]),\$Pajaro::KW_APPLY_SPLAT);
if(\$splat){
  my \@a=\@_;
  \$lf=\\\&clojure::core::list_STAR_;\$a[\$#a]=clojure::core::vary_meta(\$a[\$#a],\\\&clojure::core::dissoc,\$Pajaro::KW_APPLY_SPLAT);
  splice(\@a, $n_individual_args, \@a - $n_individual_args, \&\$lf(\@a[$n_individual_args...(\@a-1)]));
  \@_=\@a;
}
else{
  \$lf=\\\&clojure::core::list;
  splice(\@_, $n_individual_args, \@_ - $n_individual_args, (\@_ > $n_individual_args ? \&\$lf(\@_[$n_individual_args...(\@_-1)]) : undef)) # empty rest => nil, as in Clojure
}
}"));
    }
    for(my $binding_seq = clojure::core::seq($arglist_vec);
        $binding_seq;
        $binding_seq = &clojure::core::next($binding_seq)) {
        last unless defined($binding_seq);
        my $k = clojure::core::first($binding_seq);
        die 'Expected simple symbol but got '.clojure::core::pr_str($k) unless clojure::core::simple_symbol_QMARK_($k);
	die "ooops ".clojure::core::pr_str($k) if (clojure::core::name($k) =~ /_COLON__COLON_/);
	die "ooops:: ".clojure::core::pr_str($k) if (clojure::core::name($k) =~ /::/);
        if ('&' eq clojure::core::name($k)) {
            # ignore
        }
        else {
            my $kp = munge(clojure::core::name($k));
	    die "oooops $kp" if ($kp =~ /_COLON__COLON_/);
            my $sigil = '$';
            $min_args++;
	    $max_args++;
            push(@block_stmts, Pajaro::Salt::declareMy($CITATION_UNAVAILABLE, 'my', "${sigil}${kp}"));
            $env2{clojure::core::name($k)}="${sigil}${kp}";
        }
    }
    if ($vararg) { $min_args--; }
    my $label='T'.++$LABEL_COUNTER;
    push(@block_stmts, Pajaro::Salt::label($CITATION_UNAVAILABLE, $label)); ## AT THIS POINT, @_ SHOULD CONTAIN individual values for fixedly-declared parameters plus a vector for varargs
    # if (9 != @_) {die"Expected $a values to bind, but received $b, at label $label"}
    my $memo = clojure::core::pr_str($arglist_vec);
    push(@block_stmts, Pajaro::Salt::statement($CITATION_UNAVAILABLE, "if($min_args>\@_||$max_args<\@_){die(q(Expected $min_args or $max_args values to bind to $memo, but received ).(0+\@_).qq( at label $label))}"));
    $env2{'&RECUR-TO'}=$label;
    push(@block_stmts, _transpile_fn_args_assignment($arglist_vec, $env));
    push(@block_stmts, _transpile_body($body, $opts, \%env2));
    $pw=Pajaro::Salt::statements($CITATION_UNAVAILABLE, @block_stmts);
    return $pw;
}

sub _transpile_single_arity_fn_tail { # arglist and body; returns Salt of anonymous sub
    my $opts = shift;
    my $func_name_symbol = shift; # optional
    my $token_seq = shift; # arglist or multi-arity list
    my $env = shift;
    my %env2 = +( %{$env // +{}} );
    my $localVar;
    if ($func_name_symbol) {
        $localVar = '$'.munge(clojure::core::name($func_name_symbol));
        $env2{clojure::core::name($func_name_symbol)}=$localVar;
    }
    my $stmts_salt = _transpile_single_arity_fn_tail_statements($opts, $token_seq, \%env2);
    my $pw=Pajaro::Salt::namedLambda
	($CITATION_UNAVAILABLE, $localVar,
	 $stmts_salt);
    return $pw;
}

sub _special_fn_STAR_ {
    my $x = shift; # the fn* form
    my $opts = shift;
    my $env = shift; # Perl map of local/let bindings
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x);
    my $s = $x;
    (my $specialform_term, $s) = _peel_critically(\&clojure::core::simple_symbol_QMARK_, $s);
    (my $func_name, $s) = _peel_selectively(\&clojure::core::simple_symbol_QMARK_, $s);
    my $func_arg_terms_seq = $s;
    my $func_args_vec = clojure::core::first($func_arg_terms_seq);
    my ($m_cite, $func_args_meta) = Pajaro::_citation_and_user_meta($func_args_vec);
    # Opt in to infinite-lazy calling convention:
    $func_args_meta = clojure::core::assoc($func_args_meta, $Pajaro::KW_ACCEPT_APPLY_SPLAT, builtin::true);
    if (!defined(clojure::core::seq($func_args_meta))) {
	$func_args_meta=undef;
    }
    my $pw = _transpile_single_arity_fn_tail($opts, $func_name, $func_arg_terms_seq, $env);
    Pajaro::Salt::callFunction($x_cite, 'clojure::core::_adopt_sub_with_meta', $pw, transpile($opts, $func_args_meta));
}

sub _special_quote {
    my $x = shift;
    my $opts = shift;
    my $env = shift;
    my $n;
    die "Wrong number of args ($n) passed to quote"
        unless 2==($n = clojure::core::count($x));
    my $x1 = clojure::core::first(clojure::core::next($x));
    my %opts1 = (%$opts, 'QUOTE'=>6417);
    transpile(\%opts1, $x1, $env)
}

sub _special_perl_statement {
    my $x = shift;
    my $opts = shift;
    my $env = shift;
    (my $specialform_term, $x) = _peel_critically(\&clojure::core::simple_symbol_QMARK_, $x); # 'perl-statement
    my ($m_cite, $meta) = Pajaro::_citation_and_user_meta($specialform_term);
    (my $stmt, $x) = _peel_critically(\&clojure::core::string_QMARK_, $x);
    Pajaro::Salt::statement($m_cite, $stmt);
}

sub _special_case_STAR_ {
    my $x=shift;
    my $opts=shift;
    my $env=shift;
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x);
    my $s = $x;
    (my $specialform_term, $s) = _peel_critically(\&clojure::core::simple_symbol_QMARK_, $s); # 'case

    # Memoized Clojure map of case to GOTO label
    # Theory: case ==> anonymous function whose branches all 'return' their result
    # Hey, case has to be constant-time but it does not have to be "fast"
    # & { sub {
    #   my $x = shift;
    #   our $c__1 (for the map of case to GOTO label) (gensym for a distinct map per case form)
    #   if (!defined($c__1)) { ... }
    #   my $lbl = clojure::core::get($c__1, $x__1)
    #   if ($lbl) {goto $lbl}
    #   else { ...die... }
    #  L__1: return &{sub { ...expr ...}}()
    #  L__2: return &{sub { ...expr ...}}()
    # } # end sub
    # } ( EXPR )

    # But why make a special arrangement here to hoist the literal map?
    # Better solve the hoisting problem globally

    my $expr = clojure::core::first($s);
    my $expr_local_pl = '$'.clojure::core::genlocal('x__');
    my $target_local_pl = '$'.clojure::core::genlocal('l__');
    $s = clojure::core::next($s);

    # process the list of clauses into
    # (1) COWMap literal of case to label
    # (2) labels and code to compute the answer for each clause
    my $labelTable = clojure::core::hash_map();
    my @branches;
    my $dfltBranch=Pajaro::Salt::statement($x_cite, 'die', Pajaro::Salt::stringLiteral($x_cite, 'A default branch was not provided'));

    my $quote_opts = +{%{$opts}};
    $$quote_opts{'QUOTE'}=62183;

    for (; $s; $s=clojure::core::next(clojure::core::next($s))) {
	if (1 < clojure::core::count($s)) {
	    my $case_or_cases=clojure::core::first($s);
	    my ($cases_cite, $cases_user_meta) = Pajaro::_citation_and_user_meta($case_or_cases);
	    my $tail=clojure::core::first(clojure::core::rest($s));
	    my ($tail_cite, $tail_user_meta) = Pajaro::_citation_and_user_meta($tail);
	    my $label=clojure::core::genlocal("L__");
	    my $cases = (clojure::core::list_QMARK_($case_or_cases) ? clojure::core::_perl_array($case_or_cases) : +[$case_or_cases]);
	    for my $case (@{$cases}) {
		$labelTable=clojure::core::assoc($labelTable, $case, $label);
		push(@branches, Pajaro::Salt::label($cases_cite, $label));
		push(@branches, Pajaro::Salt::statement
		     ($tail_cite, 'return', Pajaro::Salt::callFunction
		      ($tail_cite, Pajaro::Salt::lambda
		       ($tail_cite, transpile($opts, $tail, $env)))));
	    }
	}
	else {
	    my $tail=clojure::core::first($s);
	    my ($tail_cite, $tail_user_meta) = Pajaro::_citation_and_user_meta($tail);
	    $dfltBranch = Pajaro::Salt::statement
		     ($tail_cite, 'return', Pajaro::Salt::callFunction
		      ($tail_cite, Pajaro::Salt::lambda
		       ($tail_cite, transpile($opts, $tail, $env))));
	}
    }
    Pajaro::Salt::callFunction
	($x_cite, Pajaro::Salt::lambda
	 ($x_cite, Pajaro::Salt::statements
	  ($x_cite,
	   Pajaro::Salt::declareMy($x_cite, 'my', $expr_local_pl, 'shift'),
	   Pajaro::Salt::declareMy($x_cite, 'my', $target_local_pl,
				 Pajaro::Salt::callFunction
				 ($x_cite, 'clojure::core::get', transpile($quote_opts, $labelTable, $env), $expr_local_pl)),
	   Pajaro::Salt::ifElsif($x_cite, Pajaro::Salt::verbatimPerl($x_cite, $target_local_pl),
			       Pajaro::Salt::statement($x_cite, 'goto', $target_local_pl),
			       $dfltBranch),
	   @branches)),
	transpile($opts, $expr, $env));
}

our $_MACRO_KW = clojure::core::keyword('macro');

sub _transpile_list {
    my $x = shift;
    my $opts = shift;
    my $env = shift;
    # case: ()
    # case: quoted ( ... )
    # case: not quoted ( special-form ... ) e.g., quote
    # case: not quoted ( macro-name arg arg ... )
    # case: not quoted ( function-expr arg arg ...)
    my $s = clojure::core::seq($x);
    my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x);
    my $salt;
    if (!defined($s)) {
	# ()
	return wrapWithMetaOf
	    (Pajaro::Salt::verbatimPerl($x_cite, '$Pajaro::COWList::EMPTY'),
	     $x, $opts);
    }
    elsif ($$opts{'QUOTE'}) {
	my @args;
	do {
	    push(@args, transpile($opts, clojure::core::first($s), $env));
	} while ($s=&clojure::core::next($s));
	return wrapWithMetaOf
	    (Pajaro::Salt::callFunction($x_cite, 'clojure::core::list', @args),
	     $x, $opts);
    }
    else {
	# case: ( special-form ... )
	my $token1 = clojure::core::first($s);
	if (clojure::core::simple_symbol_QMARK_($token1)) {
	    my $word1 = munge(clojure::core::name($token1));
	    no strict 'refs';
	    if (exists(${Pajaro::Transpiler::}{"_special_$word1"})) {
		return &{"_special_$word1"}($x, $opts, $env);
	    }
	}
	# case: ( function-expr arg arg ...)
	my $f = transpile($opts, $token1, $env);
	my @a;
	for (my $c =clojure::core::next($s); $c; $c=clojure::core::next($c)) {
	    push(@a, transpile($opts, clojure::core::first($c), $env));
	}
	#  &{ FUNC }( ARG ARG ... )
	return Pajaro::Salt::callFunction($x_cite, $f, @a);
    }
}

Pajaro::_extend_type
    (Pajaro::_intern_type('Pajaro.COWList'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>\&_transpile_list});
Pajaro::_extend_type
    (Pajaro::_intern_type('clojure.core.LazySeq'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>\&_transpile_list});
Pajaro::_extend_type
    (Pajaro::_intern_type('Pajaro.Cons'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>\&_transpile_list});
Pajaro::_extend_type
    (Pajaro::_intern_type('Pajaro.IndexedSeq'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>\&_transpile_list});

Pajaro::_extend_type
    (Pajaro::_intern_type('Perl.HASH'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift;
           my $opts = shift;
           my $env = shift;
           Pajaro::Salt::perlMapLiteral
               ($CITATION_UNAVAILABLE,
                map(transpile($opts, $_, $env), @{+[%$x]}))
       }});
Pajaro::_extend_type
    (Pajaro::_intern_type('Perl.ARRAY'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift;
           my $opts = shift;
           my $env = shift;
           Pajaro::Salt::PerlArrayRef
               ($CITATION_UNAVAILABLE,
                map(transpile($opts, $_), @{+[@$x]}))
       }});
Pajaro::_extend_type
    (Pajaro::_intern_type('Perl.Regexp'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift;
           my $opts = shift;
           my $env = shift;
           Pajaro::Salt::regexpLiteral
               ($CITATION_UNAVAILABLE,
                $x);
       }});
Pajaro::_extend_type
    (Pajaro::_intern_type('Pajaro.Keyword'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift;
           my $opts = shift;
           my $env = shift;
           my $ns = clojure::core::namespace($x);
           my $n = clojure::core::name($x);
           my @keyword_ctor_args;
           if($ns) {
               push(@keyword_ctor_args, Pajaro::Salt::stringLiteral($CITATION_UNAVAILABLE, "$ns"));
           }
           push(@keyword_ctor_args, Pajaro::Salt::stringLiteral($CITATION_UNAVAILABLE, "$n"));

	   if ($ns) {
	       Pajaro::Salt::callFunction($CITATION_UNAVAILABLE, 'clojure::core::keyword', @keyword_ctor_args)
	   }
	   else {
	       Pajaro::Salt::declareHoist
		   ($CITATION_UNAVAILABLE, '$Pajaro::UserKW::'.keyword_munge($n),
		    Pajaro::Salt::callFunction($CITATION_UNAVAILABLE, 'clojure::core::keyword', @keyword_ctor_args))
	   }
       }});
Pajaro::_extend_type
    (Pajaro::_intern_type('Pajaro.Var'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift; # note! may be rebound below
           my $opts = shift;
           my $env = shift;
           _special_var(clojure::core::list(clojure::core::symbol('var'), clojure::core::symbol($x->get_namespace(), $x->get_name())), $opts, $env)
       }});

Pajaro::_extend_type
    (Pajaro::_intern_type('Pajaro.Symbol'),
     $Pajaro::Transpiler::ITranspile,
     +{'_transpile1'=>sub
       {
           my $x = shift; # note! may be rebound below
           my $opts = shift;
           my $env = shift;
	   my ($x_cite, $x_user_meta) = Pajaro::_citation_and_user_meta($x);
           if (&clojure::core::simple_symbol_QMARK_($x)) {
               my $sym_name = clojure::core::name($x);
               if ($$opts{'QUOTE'}) {
                   return wrapWithMetaOf
                       (Pajaro::Salt::callFunction($x_cite, 'clojure::core::symbol', Pajaro::Salt::stringLiteral($x_cite, $sym_name)),
                        $x,
                       $opts);
               }
               elsif (exists($$env{$sym_name})) {
                   return Pajaro::Salt::verbatimPerl($x_cite, $$env{$sym_name});
               }
               # hmm, import-alias => dot-qualified type name
               elsif (my $dqsymtype = Pajaro::_find_type_backfill(Pajaro::_simple_symbol_default_ns_dotted($x)->name())) {
                   if ('Pajaro::Protocol' eq ref($dqsymtype)) {
                       #    $ Pa::ck::age :: Basename
                       return Pajaro::Salt::verbatimPerl($x_cite, '$' . Pajaro::_namespace_munge($sym_name));
                   }
                   else {
                       return Pajaro::Salt::callFunction
			   ($x_cite, 'Pajaro::_find_type_backfill',
			    Pajaro::Salt::stringLiteral($x_cite, $dqsymtype->name()));
                   }
               }
               else {
                   my $ans = clojure::core::deref($clojure::core::_STAR_ns_STAR_);
                   $x = clojure::core::symbol(clojure::core::name(clojure::core::ns_name($ans)),
                                          $sym_name);
                   # fall through and treat as a qualified symbol
               }
           }
           else {
               # hmm, qualified symbol possibly with alias as ns part. Expand
               my $sym_ns = clojure::core::namespace($x);
               my $sym_name = clojure::core::name($x);
               if ($$opts{'QUOTE'}) {
                   return Pajaro::Salt::callFunction
		       ($x_cite, 'clojure::core::symbol',
			Pajaro::Salt::stringLiteral($x_cite, $sym_ns),
			Pajaro::Salt::stringLiteral($x_cite, $sym_name));
               }
               #else {
               #    ...
               #}
           }
           # finish transpiling the unambiguous qualified symbol
           my $sym_ns = clojure::core::namespace($x);
           my $sym_name = clojure::core::name($x);
	   if($sym_name =~ /[.]/) {
	       print STDERR "Reflection warning: dotted ".clojure::core::pr_str($x)."\n";
               return Pajaro::Salt::callFunction($x_cite, 'Pajaro::_reflect_dotted_symbol',
                                        Pajaro::Salt::stringLiteral($x_cite, $x->namespace()),
                                        Pajaro::Salt::stringLiteral($x_cite, $x->name()));
	   }
           my $varf = clojure::core::find_var($x);
	   # Use the Var's actual namespace and name (overcome alias):
	   my $varf_ns_name;
	   my $varf_name;
	   if (clojure::core::var_QMARK_($varf)) {
	       $varf_ns_name=$varf->get_namespace();
	       $varf_name=$varf->get_name();
	       $sym_ns = $varf_ns_name;
	       $sym_name = $varf_name;
	   }

	   my $nspl = Pajaro::_namespace_munge($sym_ns);
	   my $vpl = munge($sym_name);
	   die "Dot unexpected in $vpl, supposedly in Perl notation" if ($vpl =~ /[.]/);
	   # maybe it is a Var; then again, maybe it is CODE
	   no strict 'refs';
	   Pajaro::_vivify_core_sub($nspl, $vpl);
	   if (exists(${"${nspl}::"}{$vpl})) {
	       my $scalar = ${"${nspl}::$vpl"};
	       my $pv = $nspl . '::' . $vpl;
	       if (defined($scalar)) {
		   my $p = Pajaro::Salt::verbatimPerl($x_cite, '$' . $pv);
		   if (clojure::core::var_QMARK_($varf)) {
		       $p = Pajaro::Salt::callFunction($x_cite, 'clojure::core::deref', $p);
		   }
		   else {
		       #warn "Not a var! ".clojure::core::pr_str($x) . " but rather ".(ref($varf) or $varf); # candidate for verbose logging
		   }
		   return $p;
	       }
	       elsif (\&{${"${nspl}::"}{$vpl}}) {
		   my $p =  Pajaro::Salt::verbatimPerl($x_cite, '\&' . $pv);
		   return $p;
	       }
	   }
	   else {
	       # No such slot
	       print STDERR "Reflection warning: ${nspl}::${vpl}\n";
               Pajaro::Salt::callFunction($x_cite, 'Pajaro::_reflect_qualified_symbol',
                                        Pajaro::Salt::stringLiteral($x_cite, $nspl),
                                        Pajaro::Salt::stringLiteral($x_cite, $vpl));
	   }
       }});

# opts: EVAL_VERBOSE
sub transpile { # returns a PerlWriter
    my $opts = shift;
    my $x = shift; # eg Clojure list indicating a fn call
    my $env = shift; # Perl map of local/let bindings: variable name (Perl string naming Clojure lexical)=>Perl string of Perl variable
    my $x0 = $x;
    my $ret = eval {
	if (!$$opts{'QUOTE'} && clojure::core::seq_QMARK_($x) && clojure::core::symbol_QMARK_(clojure::core::first($x))) {
	    local $clojure::core::_AMPERSAND_env = $env;
	    $x = clojure::core::macroexpand($x);
	}
	_transpile1($x, $opts, $env);
    };
    if ($@) {
	my $detail;
	{
	    local $@;
	    eval { $detail = clojure::core::_pr_str($x); };
	}
	my $orig_detail;
	{
	    local $@;
	    eval { $orig_detail = clojure::core::_pr_str($x0); };
	}
	die "$@\nThe form that incurred the error: $detail".($detail ne $orig_detail ? ' ...after macroexpanding '.$orig_detail:'');
    }
    return $ret;
}

1;
