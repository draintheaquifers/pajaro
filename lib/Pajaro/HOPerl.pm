package Pajaro::HOPerl;

# Sub wrappers around Perl builtins, enabling them for higher-order use

=pod

Perl truthiness of x

=cut

sub perl_truthy {
    my $x = shift;
    $x ? builtin::true : builtin::false
}

=pod

Member i of array a

=cut

sub aget {my $a=shift; my $i=shift; $$a[$i]}

=pod

Sets member i of array a to v

=cut

sub aset {my $a=shift; my $i=shift; my $v=shift; $$a[$i]=$v; $v}

=pod

Number of elements in array

=cut

sub alength {my $a=shift; 0+@$a}

=pod

Shallow duplicate of array

=cut

sub aclone {my $a=shift; +[@{$a}]}

=pod

Member i of hash h

=cut

sub hget {my $a=shift; my $i=shift; $$a{$i}}

=pod

Sets member i of hash h to v

=cut

sub hset {my $a=shift; my $i=shift; my $v=shift; $$a{$i}=$v; $v}

=pod

Number of key/value pairs in a Perl hash reference

=cut

sub hlength {my $a=shift; 0+%$a}

=pod

Shallow copy of a Perl hash reference

=cut

sub hclone {my $a=shift; +{%{$a}}}

=pod

New String without final newline (does not alter the given string)

=cut

sub perl_chomp { # because &CORE::chomp cannot be called directly
    my $s = shift;
    chomp $s; # modifies s and returns the number of chars removed
    $s
}

=pod

The -d file test

=cut

sub filetest_d {
    my $x = shift;
    !! ( -d $x )
}

=pod

The -l file test

=cut

sub filetest_l {
    my $x = shift;
    !! ( -l $x )
}

=pod

replace-all occurrences of m (a regex pattern string) in x with r (string or CODE ref).
If it is a CODE ref then it is invoked with a Perl array, +[$&, @{^CAPTURE}].

=cut

sub perl_replace_all {
    my $x = shift;
    my $m = shift;
    my $r = shift;
    if ('CODE' eq ref($r)) {
	$x=~s/$m/&$r(+[$&,@{^CAPTURE}])/eg;
    }
    else {
	$x=~s/$m/$r/g;
    }
    $x
}

=pod

replace-first occurrence of m (a regex pattern string) in x with r (string or CODE ref).
If it is a CODE ref then it is invoked with a Perl array, +[$&, @{^CAPTURE}].

=cut

sub perl_replace_first {
    my $x = shift;
    my $m = shift;
    my $r = shift;
    if ('CODE' eq ref($r)) {
	$x=~s/$m/&$r(+[$&,@{^CAPTURE}])/e;
    }
    else {
	$x=~s/$m/$r/;
    }
    $x
}

1;
