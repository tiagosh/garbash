#!/bin/bash -e
declare -g result; declare -g result_kind; declare -ag result_tuple;
declare -gA closure_scopes; declare -g scope_counter=0
declare -gA scope_value_0; declare -gA scope_kind_0; declare -gA value_cache
if ! type jq >/dev/null 2>&1; then echo jq not found; exit 1; fi

runtime_error() {
    echo -e "\e[0;31mRuntime error: $1\e[0m" 1>&2; exit 1;
}

assert_kind() {
    [ $result_kind != "$1" ] && runtime_error "Invalid BinaryOp kinds"
}

parse_json() {
    result=$(jq -c -r "$1")
}

try_get_from_cache() {
    local start=$1; local prop=$2
    result=${value_cache["$start"]}
    [ -n "$result" ] && return
    parse_json $prop
    value_cache["$start"]=$result
}

get_var_from_scope() {
    local name=$1; local scope_id=$2
    eval "result=\${scope_value_$scope_id['$name']}"
    eval "result_kind=\${scope_kind_$scope_id['$name']}"
    eval "local type=\${scope_kind_$scope_id[$name]}"
    [ "$type" != "Tuple" ] && return
    eval "result_tuple[0]=\${scope_kind_$scope_id['$name-first']}"
    eval "result_tuple[1]=\${scope_value_$scope_id['$name-first']}"
    eval "result_tuple[2]=\${scope_kind_$scope_id['$name-second']}"
    eval "result_tuple[3]=\${scope_value_$scope_id['$name-second']}"
}

set_var_in_scope() {
    local name=$1; local value=$2; local kind=$3; local scope_id=$4
    eval "scope_value_$scope_id['$name']=\$value"
    eval "scope_kind_$scope_id['$name']=\$kind"
}

set_tuple_in_scope() {
    local name=$1; local first_kind=$2; local first_value=$3;
    local second_kind=$4; local second_value=$5; local scope_id=$6
    eval "scope_kind_$scope_id['$name']=Tuple"
    eval "scope_value_$scope_id['$name-first']=\$first_value"
    eval "scope_kind_$scope_id['$name-first']=\$first_kind"
    eval "scope_value_$scope_id['$name-second']=\$second_value"
    eval "scope_kind_$scope_id['$name-second']=\$second_kind"
}

eval_function() {
    try_get_from_cache $3 .value <<< $1
    evaluate "$result" $2
}

eval_print() {
    local text
    try_get_from_cache $3 .value <<< $1
    evaluate "$result" $2
    case $result_kind in
    Bool) [ $result -eq 0 ] && text=false || text=true ;;
    Tuple) text="(${result_tuple[1]}, ${result_tuple[3]})" ;;
    Function) text="<#closure>" ;;
    *) text=$result ;;
    esac
    echo $text
}

eval_call() {
    local term=$1; local scope_id=$2; local counter=0; local name; local num_args
    parse_json ".callee.text,(.arguments | length)" <<< $term
    { read name; read num_args; } <<< $result
    get_var_from_scope $name $scope_id; local func_body=$result
    parse_json '.parameters[].text' <<< $func_body
    set -- $result
    local params=$result; local num_params=$#
    [ $num_args -ne $num_params ] && runtime_error "invalid number of args: $name"
    # recover original scope of this closure
    local func_id=$(cksum <<< $func_body)
    local closure_scope_id=${closure_scopes["$func_id"]}
    let scope_counter=scope_counter+1; local new_scope_id=$scope_counter
    local tmp=$(eval "declare -p scope_value_$closure_scope_id")
    eval "${tmp/scope_value_$closure_scope_id=/-g scope_value_$new_scope_id=}"
    tmp=$(eval "declare -p scope_kind_$closure_scope_id")
    eval "${tmp/scope_kind_$closure_scope_id=/-g scope_kind_$new_scope_id=}"
    for param in $params; do
        parse_json ".arguments[$counter]" <<< $term
        local tmp_arg=$result
        evaluate "$tmp_arg" $scope_id
        set_var_in_scope "$param" "$result" $result_kind $new_scope_id
        let counter=counter+1
    done
    evaluate "$func_body" $new_scope_id
}

eval_var() {
    try_get_from_cache $3 .text <<< $1
    local scope_id=$2
    get_var_from_scope $result $scope_id
}

eval_int_string() {
    try_get_from_cache $2 .value <<< $1
}

eval_bool() {
    try_get_from_cache $2 .value <<< $1
    [ ! $result = "true" ]; result=$?; result_kind=Bool
}

eval_tuple() {
    local scope_id=$2; local first_term; local second_term
    parse_json .first,.second <<< $1
    { read first_term; read second_term; } <<< $result
    evaluate "$first_term" $scope_id
    local first_value=$result; local first_kind=$result_kind
    evaluate "$second_term" $scope_id
    local second_value=$result; local second_kind=$result_kind
    result_tuple[0]=$first_kind; result_tuple[1]=$first_value;
    result_tuple[2]=$second_kind; result_tuple[3]=$second_value;
    result_kind=Tuple
}

eval_binary() {
    local term="$1"; local scope_id=$2; local tmp_lhs; local tmp_rhs; local op
    parse_json .lhs,.rhs,.op <<< $term
    { read tmp_lhs;  read tmp_rhs; read op; } <<< $result
    evaluate "$tmp_lhs" $scope_id; local lhs=$result; local lhs_kind=$result_kind
    evaluate "$tmp_rhs" $scope_id; local rhs=$result; local rhs_kind=$result_kind
    if [ $lhs_kind = $rhs_kind ]; then
        result_kind=$lhs_kind
    elif [ $lhs_kind = "Str" -o $rhs_kind = "Int" ] || [ $lhs_kind = "Int" -o $rhs_kind = "Str" ]; then
        result_kind=Str
    else
        runtime_error "BinaryOp not support for $lhs_kind $op $rhs_kind"
    fi
    case $op in
    Add)
        case $result_kind in
            Str) result="$lhs$rhs" ;;
            Int) result=$(($lhs + $rhs)) ;;
            *) runtime_error "Add BinaryOp not support for $lhs_kind + $rhs_kind" ;;
        esac
    ;;
    Sub) assert_kind Int; result=$(($lhs - $rhs)) ;;
    Mul) assert_kind Int; result=$(($lhs * $rhs)) ;;
    Div) assert_kind Int; result=$(($lhs / $rhs)) ;;
    Rem) assert_kind Int; result=$(($lhs % $rhs)) ;;
    Eq|Neq)
        if [ $result_kind == "Int" ] || [ $result_kind == "Bool" ]; then
            [ $lhs -eq $rhs ]; result=$?
        elif [ $result_kind = "Str" ]; then
            [ $lhs = $rhs ]; result=$?
        else
            runtime_error "Can't compare $lhs_kind and $rhs_kind"
        fi
        [ $op == "Eq" ] && result=$(($result == 0))
        result_kind=Bool
    ;;
    Lt) assert_kind Int; result=$(($lhs < $rhs)); result_kind=Bool ;;
    Gte) assert_kind Int; result=$(($lhs >= $rhs)); result_kind=Bool ;;
    Gt) assert_kind Int; result=$(($lhs > $rhs)); result_kind=Bool ;;
    Lte) assert_kind Int; result=$(($lhs <= $rhs)); result_kind=Bool ;;
    And|Or)
        assert_kind Bool
        if [ $op = "And" ]; then
            [ "$lhs" = "1" -a "$rhs" = "1" ]
        else
            [ "$lhs" = "1" -o "$rhs" = "1" ]
        fi
        result=$(($? == 0)); result_kind=Bool
    ;;
    *) runtime_error "$op not implemented";;
    esac
}

eval_if() {
    local term=$1; local scope_id=$2; local condition; local then; local otherwise
    parse_json .condition,.then,.otherwise <<< $term
    { read condition; read then; read otherwise; } <<< $result
    evaluate "$condition" $scope_id
    [ $result_kind != "Bool" ] && runtime_error "Invalid variable kind for If term"
    [ $result -eq 1 ] && term_to_eval=$then || term_to_eval=$otherwise
    evaluate "$term_to_eval" $scope_id
}

eval_let() {
    local term=$1; local scope_id=$2; local name; local kind;
    parse_json .name.text,.value.kind <<< $term
    { read name; read kind; } <<< $result
    try_get_from_cache $3 .value <<< $term
    if [ "$kind" != "Function" ]; then
        evaluate "$result" $scope_id
        kind=$result_kind
        if [ $result_kind = "Tuple" ]; then
            set_tuple_in_scope $name "${result_tuple[0]}" "${result_tuple[1]}" "${result_tuple[2]}" "${result_tuple[3]}" $scope_id
            return
        fi
    else
        local func_id=$(cksum <<< $result)
        closure_scopes["$func_id"]=$scope_id
    fi
    set_var_in_scope $name "$result" $kind $scope_id
}

eval_first() {
    try_get_from_cache $3 .value <<< $1
    evaluate "$result" $2
    [ $result_kind != "Tuple" ] && runtime_error "called first() on a non Tuple"
    result=${result_tuple[1]}; result_kind=${result_tuple[0]}
}

eval_second() {
    try_get_from_cache $3 .value <<< $1
    evaluate "$result" $2
    [ $result_kind != "Tuple" ] && runtime_error "called second() on a non Tuple"
    result=${result_tuple[3]}; result_kind=${result_tuple[2]}
}

evaluate() {
    local term=$1; local scope_id=$2; local kind; local start; local next
    parse_json .kind,.location.start,.next <<< $term
    { read kind; read start; read next; } <<< $result
    case $kind in
    If) eval_if "$term" $scope_id ;;
    Call) eval_call "$term" $scope_id ;;
    Binary) eval_binary "$term" $scope_id ;;
    Int|Str) eval_int_string "$term" $start; result_kind=$kind ;;
    Tuple) eval_tuple "$term" $scope_id ;;
    Var) eval_var "$term" $scope_id $start ;;
    Function) eval_function "$term" $scope_id $start ;;
    Print) eval_print "$term" $scope_id $start ;;
    First) eval_first "$term" $scope_id $start ;;
    Second) eval_second "$term" $scope_id $start ;;
    Bool) eval_bool "$term" $start ;;
    Let)
        eval_let "$term" $scope_id $start
        [ "$next" != "null" ] && evaluate "$next" $scope_id || runtime_error "No next term on Let"
    ;;
    *) runtime_error "undefined kind $kind" ;;
    esac
}
AST=${1:-/var/rinha/source.rinha.json}
json=$(jq -r .expression < $AST)
evaluate "$json" 0