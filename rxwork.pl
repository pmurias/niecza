my class Cursor {
    # has $!str
    # has $!from
    method str() { $!str }
    method from() { $!from }
}

sub _rxstar($¢, $sub) {
}

sub _rxlazymap($cs, $sub) {
    my class LazyIterator is Iterator {
        # $!valid $!value $!next  $!fun $!back
        method validate() {
            $!valid = 1;
            my $f = $!fun;
            if ! $!back.valid {
                $!back.validate;
            }
            my $bv = $!back.value;
            my $bn = $!back.next;
            # XXX horrible. we're making the value act @-ish, maybe
            Q:CgOp {
                (prog
                  (setindex value (getfield slots (cast DynObject (@ (l self))))
                    (callsub (@ (l $f)) (l $bv)))
                  (null Variable))
            };
            $!next = LazyIterator.RAWCREATE("valid", 0, "next", Any,
                "value", Any, "back", $nb, "fun", $!fun);
        }
    }

    List.RAWCREATE("flat", 1, "items", LLArray.new(), "rest",
        LLArray.new(LazyIterator.new("valid", 0, "value", Any, "next", Any,
            "back", $cs.iterator, "fun", $fun)));
}

sub _rxstr($¢, $str) {
}

# regex { a b* c }
sub rxtest($¢) {
    _rxlazymap(_rxstr($¢, 'a'), sub ($¢) { _rxlazymap(_rxstar($¢, sub ($¢) { _rxstr($¢, 'b') }), sub ($¢) { _rxstr($¢, 'c') }) })
}
