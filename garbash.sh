#!/bin/bash -e
declare -g result; declare -g result_kind; declare -ag result_tuple;
declare -gA closure_scopes; declare -g scope_counter=0
declare -gA scope_value_0; declare -gA scope_kind_0
if ! type jq >/dev/null 2>&1; then echo jq not found; exit 1; fi

parse_json() {
    result=$(jq -r "$1")
}

get_var_from_scope() {
    local name=$1; local scope_id=$2
    eval "result=\${scope_value_$scope_id['$name']}"
    eval "result_kind=\${scope_kind_$scope_id['$name']}"
    eval "local type=\${scope_kind_$scope_id[$name]}"
    if [ "$type" = "Tuple" ]; then
        eval "result_tuple[0]=\${scope_kind_$scope_id['$name-first']}"
        eval "result_tuple[1]=\${scope_value_$scope_id['$name-first']}"
        eval "result_tuple[2]=\${scope_kind_$scope_id['$name-second']}"
        eval "result_tuple[3]=\${scope_value_$scope_id['$name-second']}"
    fi
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
    parse_json .value <<< $1
    evaluate "$result" $2
}

eval_print() {
    local text
    parse_json .value <<< $1
    evaluate "$result" $2
    case $result_kind in
    Bool) [ $result -eq 0 ] &&  text=false || text=true ;;
    Tuple) text="(${result_tuple[1]}, ${result_tuple[3]})" ;;
    Function) echo "<#closure>" ;;
    *) text=$result ;;
    esac
    echo $text
}

eval_call() {
    local term=$1; local scope_id=$2; local counter=0
    parse_json .callee.text <<< $term; local name=$result
    get_var_from_scope $name $scope_id; local func_body=$result
    parse_json '.parameters[].text' <<< $result
    local params=$result; local num_params=$(echo "$result" | wc -w)
    parse_json ".arguments | length" <<< $term; local num_args=$result
    [ $num_args -ne $num_params ] && echo "invalid number of args: $name" && exit 1
    # recover original scope of this closure
    local func_id=$(cksum <<< $func_body | tr -d '[:space:]')
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
    parse_json .text <<< $1 # name
    local scope_id=$2
    get_var_from_scope $result $scope_id
}

eval_int_string() {
    parse_json .value <<< $1
}

eval_bool() {
    parse_json .value <<< $1
    [ $result = "true" ] && result=1 || result=0; result_kind=Bool
}

eval_tuple() {
    local scope_id=$2
    parse_json .first <<< $1; local first_term=$result
    evaluate "$first_term" $scope_id
    local first_value=$result; local first_kind=$result_kind
    parse_json .second <<< $1; local second_term=$result
    evaluate "$second_term" $scope_id
    local second_value=$result; local second_kind=$result_kind
    result_tuple[0]=$first_kind; result_tuple[1]=$first_value;
    result_tuple[2]=$second_kind; result_tuple[3]=$second_value;
    result_kind=Tuple
}

eval_binary() {
    local term="$1"; local scope_id=$2
    parse_json .lhs <<< $term; local tmp_lhs=$result
    parse_json .rhs <<< $term; local tmp_rhs=$result
    parse_json .op <<< $term; local op=$result

    evaluate "$tmp_lhs" $scope_id
    local lhs=$result; local lhs_kind=$result_kind
    evaluate "$tmp_rhs" $scope_id
    local rhs=$result; local rhs_kind=$result_kind
    if [ $lhs_kind = $rhs_kind ]; then
        result_kind=$lhs_kind
    elif [ $lhs_kind = "Str" -o $rhs_kind = "Str" ]; then
        result_kind=Str
    else
        echo "BinaryOp not support for $lhs_kind $op $rhs_kind"; exit 1
    fi
    case $op in
    Add)
        case $result_kind in
            Str) result="$lhs$rhs" ;;
            Int) result=$(($lhs + $rhs)) ;;
            *) echo "Add BinaryOp not support for $lhs_kind + $rhs_kind"; exit 1 ;;
        esac
    ;;
    Sub) result=$(($lhs - $rhs)) ;;
    Mul) result=$(($lhs * $rhs)) ;;
    Div) result=$(($lhs / $rhs)) ;;
    Rem) result=$(($lhs % $rhs)) ;;
    Eq) result=$(($lhs == $rhs)); result_kind=Bool ;;
    Lt) result=$(($lhs < $rhs)); result_kind=Bool ;;
    Gte) result=$(($lhs >= $rhs)); result_kind=Bool ;;
    Gt) result=$(($lhs > $rhs)); result_kind=Bool ;;
    Lte) result=$(($lhs <= $rhs)); result_kind=Bool ;;
    Neq) [ "$lhs" != "$rhs" ] && result=1 || result=0; result_kind=Bool ;;
    And) [ "$lhs" != "0" -a "$rhs" != "0" ] && result=1 || result=0; result_kind=Bool ;;
    Or) [ "$lhs" != "0" -o "$rhs" != "0" ] && result=1 || result=0; result_kind=Bool ;;
    *) echo $op not implemented; exit 1 ;;
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
    parse_json .value.kind <<< $term; local kind=$result
    parse_json .value <<< $term
    if [ "$kind" != "Function" ]; then
        evaluate "$result" $scope_id
        kind=$result_kind
        if [ $result_kind = "Tuple" ]; then
            set_tuple_in_scope $name "${result_tuple[0]}" "${result_tuple[1]}" "${result_tuple[2]}" "${result_tuple[3]}" $scope_id
            return
        fi
    else
        local func_id=$(cksum <<< $result| tr -d '[:space:]')
        closure_scopes["$func_id"]=$scope_id
    fi
    set_var_in_scope $name "$result" $kind $scope_id
}

eval_first() {
    parse_json .value <<< $1
    evaluate "$result" $2
    result=${result_tuple[1]}
    result_kind=${result_tuple[0]}
}

eval_second() {
    parse_json .value <<< $1
    evaluate "$result" $2
    result=${result_tuple[3]}
    result_kind=${result_tuple[2]}
}

evaluate() {
    local term=$1; local scope_id=$2
    parse_json .kind <<< $term; local kind=$result
    case $kind in
    If) eval_if "$term" $scope_id ;;
    Call) eval_call "$term" $scope_id ;;
    Binary) eval_binary "$term" $scope_id ;;
    Int|Str) eval_int_string "$term" $scope_id; result_kind=$kind ;;
    Tuple) eval_tuple "$term" $scope_id ;;
    Var) eval_var "$term" $scope_id ;;
    Function) eval_function "$term" $scope_id;;
    Print) eval_print "$term" $scope_id;;
    First) eval_first "$term" $scope_id;;
    Second) eval_second "$term" $scope_id;;
    Bool) eval_bool "$term" $scope_id;;
    Let)
        eval_let "$term" $scope_id
        parse_json .next <<< $term; local next=$result
        if [ "$next" != "null" ]; then
            parse_json .next <<< $term; local next_term=$result
            evaluate "$next_term" $scope_id
        fi
    ;;
    *) echo undefined kind $kind; exit 1 ;;
    esac
}
AST=${1:-/var/rinha/source.rinha.json}
json=$(jq -r .expression < $AST)
evaluate "$json" 0