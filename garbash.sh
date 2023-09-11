#!/bin/bash -e
declare -g result

eval_function() {
    local tmp=$(mktemp /tmp/garbashXXXXXXX)
    jq .value < $1 > $tmp
    evaluate $tmp $2
}

eval_print() {
    local tmp=$(mktemp /tmp/garbashXXXXXXX)
    jq .value < $1 > $tmp
    evaluate $tmp $2
    echo $result
}

eval_call() {
    local tmp=$(mktemp /tmp/garbashXXXXXXX)
    local name=$(jq -r .callee.text < $1)
    local params=$(jq -r '.parameters[].text' /tmp/garbash_$name)
    local counter=0
    for param in $params; do
        jq .arguments[$counter] < $1 > $tmp
        evaluate $tmp $2
        echo "$param=$result" >> $2
        let counter=counter+1
    done
    evaluate /tmp/garbash_$name $2
}

eval_var() {
    local name=$(jq -r .text < $1)
    source $2
    eval "result=\$$name"
}

eval_int_string() {
    result=$(jq -r .value < $1)
}

eval_binary() {
    local tmp_lhs=$(mktemp /tmp/garbashXXXXXXX)
    local tmp_rhs=$(mktemp /tmp/garbashXXXXXXX)
    jq .lhs < $1 > $tmp_lhs
    jq .rhs < $1 > $tmp_rhs
    local op=$(jq -r .op < $1)

    evaluate $tmp_lhs $2
    local lhs=$result
    evaluate $tmp_rhs $2
    local rhs=$result
    case $op in
    Add)
        result=$(expr $lhs + $rhs)
    ;;
    Sub)
        result=$(expr $lhs - $rhs)
    ;;
    Lt)
        result=$(expr $lhs '<' $rhs)
    ;;
    Mul)
        result=$(expr $lhs '*' $rhs)
    ;;
    Div)
        result=$(expr $lhs '/' $rhs)
    ;;
    Eq)
        result=$(expr "$lhs" = "$rhs")
    ;;
    Or)
        if [ "$lhs" != "0" -o "$rhs" != "0" ]; then
            result=1
        else
            result=0
        fi
    ;;
    *) # Not implemented: Rem, Neq, Gt, Lte, Gte, And
        echo $op not implemented
        exit 1
    ;;
    esac
}

eval_if() {
    local tmp_condition=$(mktemp /tmp/garbashXXXXXXX)
    jq .condition < $1 > $tmp_condition
    evaluate $tmp_condition $2
    if [ $result -eq 1 ]; then
        local tmp_then=$(mktemp /tmp/garbashXXXXXXX)
        jq .then < $1 > $tmp_then
        evaluate $tmp_then $2
    else
        local tmp_otherwise=$(mktemp /tmp/garbashXXXXXXX)
        jq .otherwise < $1 > $tmp_otherwise
        evaluate $tmp_otherwise $2
    fi
}

eval_let() {
    local name=$(jq -r .name.text < $1)
    local value=$(jq -r .value.kind < $1)
    if [ "$value" = "Function" ]; then
        jq .value < $1 > /tmp/garbash_$name
    else
        local tmp=$(mktemp /tmp/garbashXXXXXXX)
        jq .value < $1 > $tmp
        evaluate $tmp $2
        echo "$name=$result" >> $2
    fi
}

evaluate() {
    read kind <<< "$(jq -r .kind < $1)"
    local tmp_env=$2
    case $kind in
    Let)
        eval_let $1 $tmp_env
        local next=$(jq -r .next < $1)
        if [ "$next" != "null" ]; then
            local tmp_next=$(mktemp /tmp/garbashXXXXXXX)
            jq .next < $1 > $tmp_next
            evaluate $tmp_next $tmp_env
        fi
    ;;
    If)
        eval_if $1 $tmp_env
    ;;
    Binary)
        eval_binary $1 $tmp_env
    ;;
    Int|Str)
        eval_int_string $1 $tmp_env
    ;;
    Var)
        eval_var $1 $tmp_env
    ;;
    Call)
        let counter=counter+1
        local tmp_new_env=$(mktemp /tmp/garbash_call_${counter}_XXXXXXX)
        cp $tmp_env $tmp_new_env
        eval_call $1 $tmp_new_env
    ;;
    Function)
        eval_function $1 $tmp_env
    ;;
    Print)
        eval_print $1 $tmp_env
    ;;
    *) # Not Implemented: First(First),Second(Second),Bool(Bool),Tuple(Tuple)
        echo undefined kind $kind
	    exit 1
    ;;
    esac
}

> /tmp/env
jq .expression  < $1 > /tmp/start
evaluate /tmp/start /tmp/env
rm /tmp/garbash*
