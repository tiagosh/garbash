#!/bin/bash -e
declare -g result

parse_json() {
    result=$(jq -r "$1")
}

get_var_from_scope() {
    local name=$1; local scope_id=$2
    eval "result=\${scope_$scope_id['$name']}"
}

set_var_in_scope() {
    local name=$1; local value=$2; local scope_id=$3
    eval "scope_$scope_id['$name']=\$value"
}

eval_function() {
    parse_json .value <<< $1
    evaluate "$result" $2
}

eval_print() {
    parse_json .value <<< $1
    evaluate "$result" $2
    echo $result
}

eval_call() {
    local term=$1; local scope_id=$2
    parse_json .callee.text <<< $term
    local name=$result
    get_var_from_scope $name $scope_id
    parse_json '.parameters[].text' <<< $result
    local params=$result
    local counter=0
    for param in $params; do
        parse_json ".arguments[$counter]" <<< $term
        local tmp_arg=$result
        evaluate "$tmp_arg" $scope_id
        set_var_in_scope "$param" "$result" $scope_id
        let counter=counter+1
    done
    get_var_from_scope $name $scope_id
    evaluate "$result" $scope_id
}

eval_var() {
    parse_json .text <<< $1 # name
    local scope_id=$2
    get_var_from_scope $result $scope_id
}

eval_int_string() {
    parse_json .value <<< $1
}

eval_binary() {
    local term="$1"; local scope_id=$2
    parse_json .lhs <<< $term; local tmp_lhs=$result
    parse_json .rhs <<< $term; local tmp_rhs=$result
    parse_json .op <<< $term; local op=$result

    evaluate "$tmp_lhs" $2
    local lhs=$result
    evaluate "$tmp_rhs" $2
    local rhs=$result
    case $op in
    Add)
        result=$(($lhs + $rhs))
    ;;
    Sub)
        result=$(($lhs - $rhs))
    ;;
    Lt)
        result=$(($lhs < $rhs))
    ;;
    Mul)
        result=$(($lhs * $rhs))
    ;;
    Div)
        result=$(($lhs / $rhs))
    ;;
    Eq)
        result=$(($lhs == $rhs))
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
    local term=$1; local scope_id=$2
    parse_json .condition <<< $term; local condition=$result
    evaluate "$condition" $scope_id
    if [ $result -eq 1 ]; then
        parse_json .then <<< $term; local then=$result
        evaluate "$then" $scope_id
    else
        parse_json .otherwise <<< $term; local otherwise=$result
        evaluate "$otherwise" $scope_id
    fi
}

eval_let() {
    local term=$1; local scope_id=$2
    parse_json .name.text <<< $term; local name=$result
    parse_json .value.kind <<< $term; local value=$result
    if [ "$value" = "Function" ]; then
        parse_json .value <<< $term
        set_var_in_scope $name "$result" $scope_id
    else
        parse_json .value <<< $term
        evaluate "$result" $scope_id
        set_var_in_scope $name "$result" $scope_id
    fi
}

evaluate() {
    local term=$1; local scope_id=$2
    parse_json .kind <<< $term; local kind=$result
    case $kind in
    Let)
        eval_let "$term" $scope_id
        parse_json .next <<< $term; local next=$result
        if [ "$next" != "null" ]; then
            parse_json .next <<< $term; local next_term=$result
            evaluate "$next_term" $scope_id
        fi
    ;;
    If) eval_if "$term" $scope_id ;;
    Binary) eval_binary "$term" $scope_id ;;
    Int|Str) eval_int_string "$term" $scope_id;;
    Var) eval_var "$term" $scope_id ;;
    Call)
        let scope_counter=scope_counter+1
        local tmp=$(eval "declare -p scope_$scope_id")
        eval "${tmp/scope_$scope_id=/scope_$scope_counter=}"
        eval_call "$term" $scope_counter
    ;;
    Function) eval_function "$term" $scope_id;;
    Print) eval_print "$term" $scope_id;;
    *) # Not Implemented: First(First),Second(Second),Bool(Bool),Tuple(Tuple)
        echo undefined kind $kind
	    exit 1
    ;;
    esac
}

scope_counter=0; declare -gA scope_0
json=$(jq -r .expression < $1)
evaluate "$json" 0