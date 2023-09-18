#!/bin/bash -e
declare -g result

parse_json() {
    jq -r "$1"
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
    evaluate "$(parse_json .value <<< $1)" $2
}

eval_print() {
    evaluate "$(parse_json .value <<< $1)" $2
    echo $result
}

eval_call() {
    local term=$1; local scope_id=$2
    local name=$(parse_json .callee.text <<< $term)
    get_var_from_scope $name $scope_id
    local params=$(parse_json '.parameters[].text' <<< $result)
    local counter=0
    for param in $params; do
        local tmp_arg=$(parse_json ".arguments[$counter]" <<< $term)
        evaluate "$tmp_arg" $scope_id
        set_var_in_scope "$param" "$result" $scope_id
        let counter=counter+1
    done
    get_var_from_scope $name $scope_id
    evaluate "$result" $scope_id
}

eval_var() {
    local name=$(parse_json .text <<< $1)
    local scope_id=$2
    get_var_from_scope $name $scope_id
}

eval_int_string() {
    result=$(parse_json .value <<< $1)
}

eval_binary() {
    local term="$1"; local scope_id=$2
    local tmp_lhs=$(parse_json .lhs <<< $term)
    local tmp_rhs=$(parse_json .rhs <<< $term)
    local op=$(parse_json .op <<< $term)

    evaluate "$tmp_lhs" $2
    local lhs=$result
    evaluate "$tmp_rhs" $2
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
    local term=$1; local scope_id=$2
    local condition=$(parse_json .condition <<< $term)
    evaluate "$condition" $scope_id
    if [ $result -eq 1 ]; then
        local then=$(parse_json .then <<< $term)
        evaluate "$then" $scope_id
    else
        local otherwise=$(parse_json .otherwise <<< $term)
        evaluate "$otherwise" $scope_id
    fi
}

eval_let() {
    local term=$1; local scope_id=$2
    local name=$(parse_json .name.text <<< $term)
    local value=$(parse_json .value.kind <<< $term)
    if [ "$value" = "Function" ]; then
        set_var_in_scope $name "$(parse_json .value <<< $term)" $scope_id
    else
        local tmp=$(parse_json .value <<< $term)
        evaluate "$tmp" $scope_id
        set_var_in_scope $name "$result" $scope_id
    fi
}

evaluate() {
    local term=$1; local scope_id=$2
    local kind=$(parse_json .kind <<< $term)
    case $kind in
    Let)
        eval_let "$term" $scope_id
        local next=$(parse_json .next <<< $term)
        if [ "$next" != "null" ]; then
            local next_term=$(parse_json .next <<< $term)
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