# Copyright (c) 2026 by Phill Wolf. All rights reserved.
# The use and distribution terms for this software are covered by the Eclipse Public
# License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
# be found in the file epl-v10.html at the root of this distribution.
# By using this software in any fashion, you are agreeing to be bound by
# the terms of this license.
# You must not remove this notice, or any other, from this software.

package Pajaro::PEPR;

## Perl (source code) Printer (pepr)
## 
## A Perl Printer object identifies itself as an Expression or Statement
## and can serialize itself (print itself) as Perl code.
##
## A Perl Printer delegates printing of any other expressions or statements
## it contains.

package Pajaro::PEPR::Printer;
use constant {SINK_SLOT => 0};
use constant {NEXT_CITE_SLOT => 1};
use constant {WRITTEN_CITE_SLOT => 2};
use constant {BOL_SLOT => 3};
sub new {
    my $class = shift;
    my $this = +[undef,undef,undef,1];
    return bless( $this, $class);
}
sub sprintNode {
    # citation
    # node
    my $this = shift;
    my $node = shift;
    $node->print($this);
    $this
}
sub cite {
    # note for later
    my $this = shift;
    my $cite = shift; # [file, line]
    $$this[NEXT_CITE_SLOT]=$cite;
    # conditional newline to emit the citation if at BOL
    if ($$this[BOL_SLOT]) {
        $this->newLine();
    }
    $this
}
sub newLine {
    my $this = shift;
    if (!$$this[BOL_SLOT]) {
        push(@{$$this[SINK_SLOT]}, "\n");
        $$this[BOL_SLOT]=1;
    }
    # citation if pending and different from the last one
    # set BOL
    # remember cite just written
    
}
sub stuff {
    # stuff
    # update BOL depending on last character... or assume newline will be via function
}

package Pajaro::PEPR::AThing;
sub print { my $this = shift; my $h = shift ; die 'missing concrete' }
sub print1 { my $h = shift; my $x = shift; push(@{$h},$x) }
sub cite { # stuff file and line into the node for any subsequent newline
    my $this = shift;
    my $file = shift;
    my $line = shift;
    $$this{'CITE'}=+[$file,$line];
    $this
}
sub newline {
    my $this = shift;
    my $h = shift;
    push(@{$h},"\n");
    if ($$this{'CITE'}) {
        push(@{$h}, qq(# line $$this{'CITE'}[1] "$$this{'CITE'}[0]"\n));
        delete $$this{'CITE'}
    }
    $this
}   

package Pajaro::PEPR::AExpression;
our @ISA=qw(Pajaro::PEPR::AThing);
#sub printExpression { my $this = shift; $this->print(@_); }
sub asStatement {
    my $this = shift;
    new Pajaro::PEPR::Statement($this)
}
sub asExpression {
    my $this = shift;
    $this
}
package Pajaro::PEPR::AStatement;
our @ISA=qw(Pajaro::PEPR::AThing);
sub asStatement {
    my $this = shift;
    $this
}
sub asExpression {
    my $this = shift;
    new Pajaro::PEPR::CallFunction(new Pajaro::PEPR::Lambda($this))
}
package Pajaro::PEPR::Statement;
our @ISA=qw(Pajaro::PEPR::AStatement);
sub new {
    my $class = shift;
    my $this = bless(+{'TERMS'=>+[map(Pajaro::PEPR::_asExpression($_), @_)]}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    # ... ;
    my $sep = '';
    for my $term (@{$$this{'TERMS'}}) {
        Pajaro::PEPR::AThing::print1 $h, $sep;
        Pajaro::PEPR::_printThing($h, $term);
        $sep = ' ';
    }
    Pajaro::PEPR::AThing::print1 $h, ";";
}
package Pajaro::PEPR::Statements;
our @ISA=qw(Pajaro::PEPR::AStatement);
sub new {
    my $class = shift;
    my $this = bless(+{'TERMS'=>+[map(Pajaro::PEPR::_asStatement($_), @_)]}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    # ... ; ... ;
    my $sep = '';
    for my $term (@{$$this{'TERMS'}}) {
        Pajaro::PEPR::AThing::print1 $h, $sep;
        Pajaro::PEPR::_printThing($h, $term);
    }
}
package Pajaro::PEPR::DeclareMy;
our @ISA=qw(Pajaro::PEPR::Statement);
sub new {
    my $class = shift;
    my $perlCommand = shift; # e.g., "my"
    my $localVarName = shift;
    my $optionalAssignment = shift;
    if ($optionalAssignment) {
        $optionalAssignment = Pajaro::PEPR::_asExpression($optionalAssignment);
    }
    my $this = bless(+{'PERLCOMMAND'=>$perlCommand, 'LOCALVARNAME'=>$localVarName, 'ASSIGNMENT'=>$optionalAssignment}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    # my ...;
    Pajaro::PEPR::AThing::print1 $h, $$this{'PERLCOMMAND'};
    Pajaro::PEPR::AThing::print1 $h, ' ';
    Pajaro::PEPR::AThing::print1 $h, $$this{'LOCALVARNAME'};
    if ($$this{'ASSIGNMENT'}) {
        Pajaro::PEPR::AThing::print1 $h, '=';
        Pajaro::PEPR::_printThing($h, $$this{'ASSIGNMENT'});
    }
    Pajaro::PEPR::AThing::print1 $h, ';';
}
package Pajaro::PEPR::Goto;
our @ISA=qw(Pajaro::PEPR::Statement);
sub new {
    my $class = shift;
    my $destination = shift;
    my $this = bless(+{'DESTINATION'=>$destination}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    # my ...;
    Pajaro::PEPR::AThing::print1 $h, 'goto ';
    Pajaro::PEPR::_print($h, $$this{'DESTINATION'});
    Pajaro::PEPR::AThing::print1 $h, ';';
}

package Pajaro::PEPR::Block;
our @ISA=qw(Pajaro::PEPR::AStatement);
sub new {
    my $class = shift;
    my $this = bless(+{'TERMS'=>+[@_]}, $class); # which should be Statements, or a single Expression
}
sub print {
    my $this = shift;
    my $h = shift;
    # { ... }
    Pajaro::PEPR::_printBlock($h, @{$$this{'TERMS'}});
}
package Pajaro::PEPR::HashPtr;
our @ISA=qw(Pajaro::PEPR::AExpression);
sub new {
    my $class = shift;
    my $term = shift;
    my $this = bless(+{'TERM'=>Pajaro::PEPR::_asExpression($term)}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    Pajaro::PEPR::AThing::print1 $h, '+{';
    Pajaro::PEPR::_printThing($h, $$this{'TERM'});
    Pajaro::PEPR::AThing::print1 $h, '}';
}
package Pajaro::PEPR::ArrayPtr;
our @ISA=qw(Pajaro::PEPR::AExpression);
sub new {
    my $class = shift;
    my $term = shift;
    my $this = bless(+{'TERM'=>Pajaro::PEPR::_asExpression($term)}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    Pajaro::PEPR::AThing::print1 $h, '+[';
    Pajaro::PEPR::_printThing($h, $$this{'TERM'});
    Pajaro::PEPR::AThing::print1 $h, ']';
}
package Pajaro::PEPR::ClojureList;
our @ISA=qw(Pajaro::PEPR::AExpression);
sub new {
    my $class = shift;
    my $this = bless(+{'TERMS'=>+[@_]}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    Pajaro::PEPR::AThing::print1 $h, '&clojure::core::list';
    Pajaro::PEPR::_printCommaSepListInParens($h, @{$$this{'TERMS'}});
}
package Pajaro::PEPR::PerlList;
our @ISA=qw(Pajaro::PEPR::AExpression);
sub new {
    my $class = shift;
    my $this = bless(+{'TERMS'=>+[@_]}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    # (..., ..., ...)
    Pajaro::PEPR::_printCommaSepListInParens($h, @{$$this{'TERMS'}});
}
package Pajaro::PEPR::PerlArrayRef;
our @ISA=qw(Pajaro::PEPR::AExpression);
sub new {
    my $class = shift;
    my $this = bless(+{'TERMS'=>+[map(Pajaro::PEPR::_asExpression($_), @_)]}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    # +[ ..., ..., ... ]
    Pajaro::PEPR::AThing::print1 $h, '+[';
    Pajaro::PEPR::_printCommaSepList($h, @{$$this{'TERMS'}});
    Pajaro::PEPR::AThing::print1 $h, ']';
}
package Pajaro::PEPR::Assign;
our @ISA=qw(Pajaro::PEPR::AExpression);
sub new {
    my $class = shift;
    my $lvalue = shift;
    my $rvalue = shift;
    my $this = bless(+{'LVALUE'=>Pajaro::PEPR::_asExpression($lvalue),
                           'RVALUE'=>Pajaro::PEPR::_asExpression($rvalue)}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    # lv = rv
    Pajaro::PEPR::_printThing($h, $$this{'LVALUE'});
    Pajaro::PEPR::AThing::print1 $h, ' = ';
    Pajaro::PEPR::_printThing($h, $$this{'RVALUE'});
}
package Pajaro::PEPR::String;
our @ISA=qw(Pajaro::PEPR::AExpression);
sub new {
    my $class = shift;
    my $this = bless(+{'TEXT'=>shift}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    my $p = $$this{'TEXT'};
    my @delims = ('(',')',';',',');
    my %detox = map(($_=>1),
                    (@delims, q('), q("), q(\\), q($), q(@)));
    my $interpolation_needed = 0; # for hex escapes, not variables
    for (my $i = length($p)-1; $i>=0; $i--) {
        my $c = substr($p, $i, 1);
        my $o = ord($c);
        my $d = ($o < 32 || $o >127 || exists($detox{$c}))
            ? sprintf('\\x{%x}',$o)
            : undef;
        if ($d) {
            substr($p,$i,1)=$d;
            $interpolation_needed=1;
        }
    }
    my $op = $interpolation_needed?'qq':'q';
    Pajaro::PEPR::AThing::print1 $h, $op.$delims[0].$p.$delims[1];
}
package Pajaro::PEPR::RawExpression;
our @ISA=qw(Pajaro::PEPR::AExpression);
sub new {
    my $class = shift;
    my $this = bless(+{'X'=>shift}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    # ...
    Pajaro::PEPR::AThing::print1 $h, $$this{'X'};
}
package Pajaro::PEPR::PerlMapLiteral; # k,v,k,v (each one already transpiled; keys should be Caper strings to avoid messy redundant #perl output)
our @ISA=qw(Pajaro::PEPR::AExpression);
sub new {
    my $class = shift;
    my @kvkvs = map(Pajaro::PEPR::_asExpression($_),@_);
    my $this = bless(+{'KVKVS'=>+[@kvkvs]}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    my $sep='';
    Pajaro::PEPR::AThing::print1 $h, '+{';
    my $kvkvs = $$this{'KVKVS'};
    for my ($k,$v) (@$kvkvs) {
        Pajaro::PEPR::AThing::print1 $h, $sep;
        Pajaro::PEPR::_printThing($h,$k);
        Pajaro::PEPR::AThing::print1 $h, '=>';
        Pajaro::PEPR::_printThing($h,$v);
        $sep=',';
    }
    Pajaro::PEPR::AThing::print1 $h, '}';
}    
package Pajaro::PEPR::CallClassMethod;
our @ISA=qw(Pajaro::PEPR::AExpression);
sub new {
    my $class = shift;
    my $perlclass = shift;
    my $method = shift;
    my @args = @_;
    my $this = bless(+{'CLASS'=>$perlclass, 'METHOD'=>$method, 'ARGS'=>+[@args]}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    # method Class(arg, ...)
    Pajaro::PEPR::AThing::print1 $h, $$this{'METHOD'};
    Pajaro::PEPR::AThing::print1 $h, ' ';
    Pajaro::PEPR::AThing::print1 $h, $$this{'CLASS'};
    Pajaro::PEPR::_printCommaSepListInParens($h, @{$$this{'ARGS'}});
}
package Pajaro::PEPR::CallInstanceMethod;
our @ISA=qw(Pajaro::PEPR::AExpression);
sub new {
    my $class = shift;
    my $object = shift;
    my $method = shift;
    my @args = @_;
    $object = Pajaro::PEPR::_asExpression($object);
    @args = map(Pajaro::PEPR::_asExpression($_),@args);
    my $this = bless(+{'OBJECT'=>$object, 'METHOD'=>$method, 'ARGS'=>+[@args]}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    # object->method(arg, ...)
    Pajaro::PEPR::_printThing($h, $$this{'OBJECT'});
    Pajaro::PEPR::AThing::print1 $h, '->';
    Pajaro::PEPR::AThing::print1 $h, $$this{'METHOD'};
    Pajaro::PEPR::_printCommaSepListInParens($h, @{$$this{'ARGS'}});
}
package Pajaro::PEPR::Infix;
our @ISA=qw(Pajaro::PEPR::AExpression);
sub new {
    my $class = shift;
    my $operator = shift;
    my @args = @_;
    my $this = bless(+{'OPERATOR'=>$operator, 'ARGS'=>+[@args]}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    Pajaro::PEPR::AThing::print1 $h, '(';
    my $sep = 0;
    for my $j (@{$$this{'ARGS'}}) {
        if ($sep) {
            Pajaro::PEPR::AThing::print1 $h, ' ';
            Pajaro::PEPR::_printExpression($h, $$this{'OPERATOR'});
            Pajaro::PEPR::AThing::print1 $h, ' ';
        }
        Pajaro::PEPR::_printExpression($h, $j);
        $sep=1;
    }
    Pajaro::PEPR::AThing::print1 $h, ')';
}
package Pajaro::PEPR::CallFunction; # function may be a string or expression
our @ISA=qw(Pajaro::PEPR::AExpression);
sub new {
    my $class = shift;
    my $function = shift;
    my @args = @_;
    $function = Pajaro::PEPR::_asExpression($function);
    @args = map(Pajaro::PEPR::_asExpression($_), @args);
    my $this = bless(+{'FUNCTION'=>$function, 'ARGS'=>+[@args]}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    # &{function}(arg, ...)
    if (!ref($$this{'FUNCTION'})) {
        Pajaro::PEPR::AThing::print1 $h, '&';
        Pajaro::PEPR::_printThing($h, $$this{'FUNCTION'});
    }
    else {
        Pajaro::PEPR::AThing::print1 $h, '&{';
        Pajaro::PEPR::_printThing($h, $$this{'FUNCTION'});
        Pajaro::PEPR::AThing::print1 $h, '}';
    }
    Pajaro::PEPR::_printCommaSepListInParens($h, @{$$this{'ARGS'}});
}
package Pajaro::PEPR::Lambda;
our @ISA=qw(Pajaro::PEPR::AExpression);
sub new {
    my $class = shift;
    my @body = @_;
    my $this = bless(+{'BODY'=>+[@body]}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    # sub{...}
    Pajaro::PEPR::_printLambda($h, @{$$this{'BODY'}});
}
package Pajaro::PEPR::NamedLambda;
our @ISA=qw(Pajaro::PEPR::AExpression);
sub new {
    my $class = shift;
    my $localVarName = shift; # optional
    my @body = @_;
    my $this = bless(+{'LOCALVARNAME'=>$localVarName, 'BODY'=>+[@body]}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    if ($$this{'LOCALVARNAME'}) {
        # &{sub{my $subname; $subname = sub{}}}()
        # because $subname must be in-scope in the innermost sub,
        # but its scope begins with the statement AFTER the my
        Pajaro::PEPR::AThing::print1 $h, '&{sub{my ';
        Pajaro::PEPR::AThing::print1 $h, $$this{'LOCALVARNAME'};
        Pajaro::PEPR::AThing::print1 $h, '; ';
        Pajaro::PEPR::AThing::print1 $h, $$this{'LOCALVARNAME'};
        Pajaro::PEPR::AThing::print1 $h, '=';
        Pajaro::PEPR::_printLambda($h, @{$$this{'BODY'}});
        Pajaro::PEPR::AThing::print1 $h, '}}()';
    }
    else {
        # sub{...}
        Pajaro::PEPR::_printLambda($h, @{$$this{'BODY'}});
    }
}
package Pajaro::PEPR::Label;
our @ISA=qw(Pajaro::PEPR::AStatement);
sub new {
    my $class = shift;
    my $this = bless(+{'X'=>shift}, $class);
}
sub print {
    my $this = shift;
    my $h = shift;
    # ...:
    Pajaro::PEPR::AThing::print1 $h, $$this{'X'};
    Pajaro::PEPR::AThing::print1 $h, ': ';
}
sub asExpression {
    die 'Cannot render a label as an expression';
}
package Pajaro::PEPR::IfElsifStatement;
our @ISA=qw(Pajaro::PEPR::AStatement);
sub new {
    my $class=shift;
    my @pairs=@_; # [ expression, things-for-block, ... ]
    return bless(+{'PAIRS'=>+[@pairs]}, $class);
}
sub print {
    my $this=shift;
    my $h = shift;
    my @cb = @{$$this{'PAIRS'}};
    my $opword = 'if';
    for (; @cb;) {
        my $condition;
        my $block;
        if (@cb > 1) {
            $condition = shift(@cb);
            $condition = Pajaro::PEPR::_asExpression($condition);
            my $stmts = shift(@cb);
            Pajaro::PEPR::AThing::print1 $h, $opword;
            $opword = " elsif";
            Pajaro::PEPR::AThing::print1 $h, '(';
            Pajaro::PEPR::_printThing($h, $condition);
            Pajaro::PEPR::AThing::print1 $h, ')';
            Pajaro::PEPR::_printBlock($h, @$stmts);
        }
        else {
            my $stmts = shift(@cb);
            Pajaro::PEPR::AThing::print1 $h, ' else ';
            Pajaro::PEPR::_printBlock($h, @$stmts);
        }
    }
}

package Pajaro::PEPR;

sub _print {
    my $h = shift;
    my $x = shift;
    if (!ref($x)) {
	Pajaro::PEPR::AThing::print1 $h, $x;
    }
    else {
	$x->print($h);
    }
}
sub _printThing {
    my $h = shift;
    my $x = shift;
    if (!ref($x)) {
	Pajaro::PEPR::AThing::print1 $h, $x;
    }
    elsif (!Scalar::Util::blessed($x)) {
        die ("can't _printExpression an unblessed ".ref($x)."\n");
    }
    elsif (! $x->isa(Pajaro::PEPR::AThing)) {
	die ("expected string or Pajaro::PEPR::AThing, got ".ref($x)." of $x");
    }
    else {
	$x->print($h);
    }
}
sub _printLambda { # sub{...}
    # one s/e or multiple s ;
    my $h = shift;
    _allThings(@_);
    my @body = @_;
    # sub {...}
    Pajaro::PEPR::AThing::print1 $h, 'sub';
    _printBlock($h, @body);
}
sub _printBlock {
    my $h = shift;
    _allThings(@_);
    my @terms = @_;
    # { ... }
    Pajaro::PEPR::AThing::print1 $h, "{";
    if ( 1 == @terms) {
	_print($h,$terms[0]); # let it be stmt or expression
    }
    else {
	for my $term (@terms) {
	    Pajaro::PEPR::_printStatement($h, $term);
	}
    }
    Pajaro::PEPR::AThing::print1 $h, "}";
}
sub _printCommaSepList {
    my $h = shift;
    my @terms = @_;
    my $sep = '';
    for my $term (@terms) {
        Pajaro::PEPR::AThing::print1 $h, $sep;
        Pajaro::PEPR::_printThing($h, $term);
        $sep = ', ';
    }
}
sub _printCommaSepListInParens {
    my $h = shift;
    _allThings(@_);
    my @terms = @_;
    # (..., ..., ...)
    Pajaro::PEPR::AThing::print1 $h, '(';
    _printCommaSepList($h, @terms);
    Pajaro::PEPR::AThing::print1 $h, ')';
}

sub _asExpression {
    my $x = shift;
    if ($x->isa(Pajaro::PEPR::AThing)) {
        $x->asExpression()
    }
    else {
        $x
    }
}
sub _asStatement {
    my $x = shift;
    if ($x->isa(Pajaro::PEPR::AThing)) {
        $x->asStatement()
    }
    else {
        new Pajaro::PEPR::Statement($x)
    }
}

sub _allThings { # Everything is a string, a Pajaro::PEPR::AThing, or an array
    my @args = @_;
    for my $arg (@args) {
	if (ref($arg) && (ref($arg) ne 'ARRAY' && (!Scalar::Util::blessed($arg) || !$arg->isa(Pajaro::PEPR::AThing)))) {
	    die ("expected string or Pajaro::PEPR::AThing, got ".ref($arg));
	}
    }
}

# Important! None of the following does any munging.

## PEPR API

=over

=item C<rawExpression($verbatim)> — Verbatim stuff.

=item C<stringLiteral($text)> — String literal expression (chooses suitable quoting mechanism and escapes special characters).

=item C<assign($lvalueNode, $rvalueNode)> — Assignment expression node (C<lvalue = rvalue>).

=item C<ClojureList(@itemNodes)> — C<&Pajaro::PEPR::list( item1, item2, ... )>

=item C<PerlList(@itemNodes)> — C<( item1, item2, ... )>

=item C<PerlArrayRef(@itemNodes)> — C<+[ item1, item2, ... ]>

=item C<callClassMethod($class, $method, @argNodes)> — C<method Class( arg1, arg2, ... )>

=item C<callInstanceMethod($object, $method, @argNodes)> — C<object-\>method( arg1, arg2, ... )>

=item C<callFunction($function, @argNodes)> — C<&{function}( arg1, arg2, ... )>.

=item C<lambda(@stmtOrExprNodes)> — C<sub{ ... }>

=item C<namedLambda($localVarName, @stmtOrExprNodes)> — C<&{sub{my $v; $v=sub{...}}}()> (a self-referencing named lambda expression node). If localVarName is undef, then the output is the same as from lambda.

=item C<perlMapLiteral($kNode, $vNode, ...)> — C<+{k1, v1, ...}> (Perl hash reference expression node from alternating key-value pairs).

=item C<statement(@termNodes)> — C< term1 term2 term3 ; > (Semicolon-terminated statement from space-separated expression terms)

=item C<statements(@stmts)> — Sequence-of-statements node. (Terms are printed without separation.)

=item C<block(@terms)> — C<{ ... }>. Terms may be 1 expression or N statements.

=item C<ifElsif(expr1,stmts1)> — C<if (expr1) { stmts1 } elsif (expr2) { ...> from alternating condition/body pairs.

=item C<label($name)> — Label statement node (C<name:>).

=item C<declareMy($scopeWord, $varname, $assignment)> — scopeWord should be 'my' or 'our'. Variable declaration statement node (C<my $var = ...;>).

=item C<goto_($destination)> — Goto statement node (C<goto destination;>).

=item C<hashPtr($term)> — Hash reference expression node wrapping a term in C<+{...}>.

=item C<arrayPtr($term)> — Array reference expression node wrapping a term in C<+[...]>.

=item C<infix($operator, @args)> — Infix operator expression node (C<(a op b op ...)>).

=back

=cut

sub rawExpression { _allThings(@_); new Pajaro::PEPR::RawExpression(@_); }
sub stringLiteral { _allThings(@_); new Pajaro::PEPR::String(@_); }
sub assign { _allThings(@_); new Pajaro::PEPR::Assign(@_); }
sub ClojureList { _allThings(@_); new Pajaro::PEPR::ClojureList(@_); }
sub PerlList { _allThings(@_); new Pajaro::PEPR::PerlList(@_); }
sub PerlArrayRef { _allThings(@_); new Pajaro::PEPR::PerlArrayRef(@_); }
sub callClassMethod { _allThings(@_); new Pajaro::PEPR::CallClassMethod(@_); }
sub callInstanceMethod { _allThings(@_); new Pajaro::PEPR::CallInstanceMethod(@_); }
sub callFunction { _allThings(@_); new Pajaro::PEPR::CallFunction(@_); }
sub lambda { _allThings(@_); new Pajaro::PEPR::Lambda(@_); }
sub namedLambda { _allThings(@_); new Pajaro::PEPR::NamedLambda(@_); }
sub perlMapLiteral { new Pajaro::PEPR::PerlMapLiteral(@_); }
# Statements
sub statement { _allThings(@_); new Pajaro::PEPR::Statement(@_); }
sub statements { _allThings(@_); new Pajaro::PEPR::Statements(@_); }
sub block { _allThings(@_); new Pajaro::PEPR::Block(@_); }
sub ifElsif { _allThings(@_); new Pajaro::PEPR::IfElsifStatement(@_); }
sub label { _allThings(@_); new Pajaro::PEPR::Label(@_);}
sub declareMy { _allThings(@_); new Pajaro::PEPR::DeclareMy(@_); }
sub goto_ { _allThings(@_); new Pajaro::PEPR::Goto(@_); }
sub hashPtr { _allThings(@_); new Pajaro::PEPR::HashPtr(@_); }
sub arrayPtr { _allThings(@_); new Pajaro::PEPR::ArrayPtr(@_); }
sub infix { _allThings(@_); new Pajaro::PEPR::Infix(@_); }

1;
