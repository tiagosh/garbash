#!/bin/bash -e
declare -g result; declare -g result_kind; declare -ag result_tuple;
declare -gA closure_scopes; declare -g scope_counter=0; declare -gA memoize_blacklist
declare -gA json_cache; declare -gA result_cache; declare -gA result_kind_cache
declare -gA scope_id_map;
if ! type jj >/dev/null 2>&1; then echo jj not found; exit 1; fi

runtime_error() {
    echo -e "\e[0;31mRuntime error: $1\e[0m" 1>&2; exit 1;
}

assert_kind() {
    [ $result_kind != "$1" ] && runtime_error "Invalid BinaryOp kinds"
}

new_scope() {
    local original_scope=$1
    let scope_counter=scope_counter+1; new_scope_id=$scope_counter
    local tmp=$(eval "declare -p scope_value_$original_scope")
    eval "${tmp/scope_value_$original_scope=/-g scope_value_$new_scope_id=}"
    tmp=$(eval "declare -p scope_kind_$original_scope")
    eval "${tmp/scope_kind_$original_scope=/-g scope_kind_$new_scope_id=}"
}

drop_scope() {
    eval "unset scope_value_$1; unset scope_kind_$1"
}

set_arguments_to_scope() {
    local orig_scope_id=$1; local num_args=$2; local term=$3; local callee=$4; local recover_scope=$5; local func_id=$(cksum <<< $callee)
    [ $recover_scope -eq 1 ] && [ -v "closure_scopes['$func_id']" ] && local scope_id=${closure_scopes["$func_id"]} || local scope_id=$orig_scope_id
    new_scope $scope_id; local this_new_scope_id=$new_scope_id
    parse_json '.parameters[].text' <<< $callee
    set -- $result
    local params=$result; local num_params=$#
    [ $num_args -ne $num_params ] && runtime_error "invalid number of args"
    local arguments_cache; local counter=0
    for param in $params; do
        parse_json ".arguments[$counter]" <<< $term
        local tmp_arg=$result
        evaluate "$tmp_arg" $scope_id
        arguments_cache=$arguments_cache$result
        if [ $result_kind = "Tuple" ]; then
            set_tuple_in_scope $param "${result_tuple[0]}" "${result_tuple[1]}" $this_new_scope_id
        else
            set_var_in_scope "$param" "$result" $result_kind $this_new_scope_id
        fi
        let counter=counter+1
    done
    result_cache_key="$func_id$arguments_cache"; new_scope_id=$this_new_scope_id
    result=${result_cache["$result_cache_key"]}; result_kind=${result_kind_cache["$result_cache_key"]}
}

parse_json() {
    local path=$1; local json
    read -r json; local json_id=$(cksum <<< "$json$path")
    result=${json_cache["$json_id"]}
    [ -n "$result" ] && return
    result=$(jq -c -r "$path" <<< $json)
    json_cache["$json_id"]=$result
}

parse_json_jj() {
    local path=$1; local json
    read -r json; local json_id=$(cksum <<< "$json$path")
    result=${json_cache["$json_id"]}
    [ -n "$result" ] && return
    result=$(jj -un "$path" <<< $json)
    json_cache["$json_id"]=$result
}

get_var_from_scope() {
    local name=$1; local scope_id=$2
    [ ! -v "scope_value_$scope_id['$name']" -a ! -v "scope_value_$scope_id['$name-first']" ] && runtime_error "Variable $name not defined"
    eval "result=\${scope_value_$scope_id['$name']}"
    eval "result_kind=\${scope_kind_$scope_id['$name']}"
    eval "local type=\${scope_kind_$scope_id[$name]}"
    [ "$type" != "Tuple" ] && return
    eval "result_tuple[0]=\${scope_value_$scope_id['$name-first']}"
    eval "result_tuple[1]=\${scope_value_$scope_id['$name-second']}"
}

set_var_in_scope() {
    local name=$1; local value=$2; local kind=$3; local scope_id=$4
    eval "scope_value_$scope_id['$name']=\$value"
    eval "scope_kind_$scope_id['$name']=\$kind"
}

set_tuple_in_scope() {
    local name=$1; local first_value=$2; local second_value=$3; local scope_id=$4
    eval "scope_kind_$scope_id['$name']=Tuple"
    eval "scope_value_$scope_id['$name-first']=\$first_value"
    eval "scope_value_$scope_id['$name-second']=\$second_value"
}

eval_function() {
    local func=$1; local scope_id=$2; local func_id=$(cksum <<< $func)
    closure_scopes["$func_id"]=$scope_id
    set_var_in_scope "$func_id" "$func" Function $scope_id
    result=$func; result_kind=Function; result_func_id=$func_id
}

print_function() {
    print_output="<#closure>"
}

print_tuple() {
    local scope_id=$1; local tuple_first=$2; local tuple_second=$3; local output="(";
    for entry in "$tuple_first" "$tuple_second"; do
        evaluate "$entry" $scope_id; local first=$result; local first_kind=$result_kind
        if [ $first_kind = "Tuple" ]; then
            print_tuple $scope_id "${result_tuple[0]}" "${result_tuple[1]}"; result=$print_output
        elif [ $first_kind = "Function" ]; then
            print_function; result=$output
        fi
        output="$output$result, "
    done
    output=${output::-2}; output="$output)"; print_output=$output
}

eval_print() {
    local text
    memoize_blacklist[$scope_id]=1
    parse_json_jj value <<< $1
    evaluate "$result" $2
    case $result_kind in
    Bool) [ $result -eq 0 ] && text=false || text=true ;;
    Tuple)
        print_tuple $2 "${result_tuple[0]}" "${result_tuple[1]}"
        text=$print_output
    ;;
    Function) print_function; text=$print_output ;;
    *) text=$result ;;
    esac
    echo "$text"
}

eval_call() {
    local term=$1; local scope_id=$2;
    local var_name; local num_args; local callee; local callee_kind; local callee_num_args
    parse_json_jj callee <<< $term; callee=$result
    parse_json_jj callee.kind <<< $term; callee_kind=$result
    parse_json_jj callee.value <<< $term; callee_body=$result
    parse_json_jj callee.text <<< $term; var_name=$result
    parse_json_jj 'arguments|#' <<< $term; num_args=$result
    parse_json_jj 'callee.arguments|#' <<< $term; callee_num_args=$result
    case $callee_kind in
    Function)
        set_arguments_to_scope $scope_id $num_args "$term" "$callee" 1; local this_new_scope_id=$new_scope_id
        parse_json_jj value <<< $callee; local callee_body=$result
        evaluate "$callee_body" $this_new_scope_id
    ;;
    Var)
        [ "${scope_id_map[$scope_id]}" != "$var_name" ] && memoize_blacklist[$scope_id]=1
        get_var_from_scope $var_name $scope_id; callee=$result;
        set_arguments_to_scope $scope_id "$num_args" "$term" "$callee" 0; local this_new_scope_id=$new_scope_id
        scope_id_map[$this_new_scope_id]=$var_name
        local this_cache_key=$result_cache_key
        [ -n "$result" ] && return
        parse_json_jj value <<< $callee; local callee_body=$result
        evaluate "$callee_body" $this_new_scope_id
        [ "${memoize_blacklist[$this_new_scope_id]}" = "1" ] && return
        [ -n "$this_cache_key" ] && result_cache["$this_cache_key"]=$result && result_kind_cache["$this_cache_key"]=$result_kind
        return
    ;;
    Call)
        evaluate "$callee" $scope_id; local callee_body=$result
        set_arguments_to_scope $scope_id $num_args "$term" "$callee_body" 1; local this_new_scope_id=$new_scope_id
        parse_json_jj value <<< $callee_body; local callee_body=$result
        evaluate "$callee_body" $this_new_scope_id
    ;;
    *) runtime_error "Call to invalid Term" ;;
    esac
    if [ $result_kind == "Function" ]; then
        local func_id=$(cksum <<< $result)
        [ ! -v "closure_scopes['$func_id']" ] && runtime_error "No closure scope found"
        parse_json_jj value <<< $result; local callee_body=$result
        set_arguments_to_scope $scope_id $callee_num_args "$term" "$callee_body" 1; local this_new_scope_id=$new_scope_id
        evaluate "$callee_body" $this_new_scope_id
    fi
}

resolve_tuple() {
    local scope_id=$1; local tuple_first=$2; local tuple_second=$3;
    local output='{"kind":"Tuple","first":'
    evaluate "$tuple_first" $scope_id
    case $result_kind in
    Int|Bool) output="{\"kind\":\"$result_kind\",\"value\":$result:}" ;;
    Str) "{\"kind\":\"$result_kind\",\"value\":\"$result\":}" ;;
    Tuple) resolve_tuple; output="$output$result"
    esac
    evaluate "$tuple_second" $scope_id
    output="$output,\"second\":"
    case $result_kind in
    Int|Bool) output="{\"kind\":\"$result_kind\",\"value\":$result:}" ;;
    Str) "{\"kind\":\"$result_kind\",\"value\":\"$result\":}" ;;
    Tuple) resolve_tuple; output="$output$result"
    esac
    output="}"; resolve_tuple_output=$output
}

eval_var() {
    parse_json_jj text <<< $1
    local scope_id=$2
    get_var_from_scope $result $scope_id
}

eval_int_string() {
    parse_json_jj value <<< $1
}

eval_bool() {
    parse_json_jj value <<< $1
    [ ! $result = "true" ]; result=$?; result_kind=Bool
}

eval_tuple() {
    local scope_id=$2; local first_term; local second_term
    parse_json_jj first <<< $1; first_term=$result
    evaluate "$result" $scope_id
    first_term="{\"kind\":\"$result_kind\",\"value\":\"$result\"}"
    if [ $result_kind = "Tuple" ]; then
        evaluate "${result_tuple[0]}" $scope_id
        local result_first=$result
        if [ $result_kind != "Tuple" ]; then
            result_first="{\"kind\":\"$result_kind\",\"value\":\"$result\"}"
        fi
        evaluate "${result_tuple[1]}" $scope_id
        local result_second=$result
        if [ $result_kind != "Tuple" ]; then
            result_second="{\"kind\":\"$result_kind\",\"value\":\"$result\"}"
        fi
        first_term="{\"kind\":\"Tuple\",\"first\":$result_first,\"second\":$result_second}"
    fi
    parse_json_jj second <<< $1; second_term=$result
    evaluate "$result" $scope_id
    second_term="{\"kind\":\"$result_kind\",\"value\":\"$result\"}"
    if [ $result_kind = "Tuple" ]; then
        evaluate "${result_tuple[0]}" $scope_id
        local result_first=$result
        if [ $result_kind != "Tuple" ]; then
            result_first="{\"kind\":\"$result_kind\",\"value\":\"$result\"}"
        fi
        evaluate "${result_tuple[1]}" $scope_id
        local result_second=$result
        if [ $result_kind != "Tuple" ]; then
            result_second="{\"kind\":\"$result_kind\",\"value\":\"$result\"}"
        fi
        second_term="{\"kind\":\"Tuple\",\"first\":$result_first,\"second\":$result_second}"
    fi
    result="{\"kind\":\"Tuple\",\"first\":$first_term,\"second\":$second_term}"
    result_tuple[0]=$first_term; result_tuple[1]=$second_term;
    result_kind=Tuple
}

eval_binary() {
    local term="$1"; local scope_id=$2; local tmp_lhs; local tmp_rhs; local op
    parse_json_jj lhs <<< $term; tmp_lhs=$result
    parse_json_jj rhs <<< $term; tmp_rhs=$result
    parse_json_jj op <<< $term; op=$result
    evaluate "$tmp_lhs" $scope_id; local lhs=$result; local lhs_kind=$result_kind
    evaluate "$tmp_rhs" $scope_id; local rhs=$result; local rhs_kind=$result_kind
    if [ $lhs_kind = $rhs_kind ]; then
        result_kind=$lhs_kind
    elif [ $lhs_kind = "Str" -a $rhs_kind = "Int" ] || [ $lhs_kind = "Int" -a $rhs_kind = "Str" ]; then
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
            [ "$lhs" = "$rhs" ]; result=$?
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
    parse_json_jj condition <<< $term; condition=$result
    parse_json_jj then <<< $term; then=$result
    parse_json_jj otherwise <<< $term; otherwise=$result
    evaluate "$condition" $scope_id
    [ $result_kind != "Bool" ] && runtime_error "Invalid variable kind for If term"
    [ $result -eq 1 ] && term_to_eval=$then || term_to_eval=$otherwise
    evaluate "$term_to_eval" $scope_id
}

eval_let() {
    local term=$1; local scope_id=$2; local name;
    parse_json_jj name.text <<< $term; name=$result
    parse_json_jj value <<< $term
    evaluate "$result" $scope_id
    [ -z "$result_kind" ] && return
    if [ $result_kind = "Tuple" ]; then
        set_tuple_in_scope $name "${result_tuple[0]}" "${result_tuple[1]}" $scope_id
        return
    fi
    [ $name = "_" ] && return
    set_var_in_scope $name "$result" $result_kind $scope_id
}

eval_tuple_entry() {
    parse_json_jj value <<< $2
    evaluate "$result" $3
    evaluate "${result_tuple[$1]}" $3
}

evaluate() {
    local term=$1; local scope_id=$2; local kind; local next
    parse_json_jj kind <<< $term; kind=$result
    [ "$kind" = "Let" ] && parse_json_jj next <<< $term; next=$result
    case $kind in
    If) eval_if "$term" $scope_id ;;
    Call) eval_call "$term" $scope_id ;;
    Binary) eval_binary "$term" $scope_id ;;
    Int|Str) eval_int_string "$term"; result_kind=$kind ;;
    Tuple) eval_tuple "$term" $scope_id ;;
    Var) eval_var "$term" $scope_id ;;
    Function) eval_function "$term" $scope_id ;;
    Print) eval_print "$term" $scope_id ;;
    First) eval_tuple_entry 0 "$term" $scope_id ;;
    Second) eval_tuple_entry 1 "$term" $scope_id ;;
    Bool) eval_bool "$term" ;;
    Let)
        eval_let "$term" $scope_id
        [ "$next" != "" ] && evaluate "$next" $scope_id || runtime_error "No next term on Let"
    ;;
    *) runtime_error "undefined kind $kind" ;;
    esac
}
AST=${1:-/var/rinha/source.rinha.json}
json=$(jj -un expression < $AST)
declare -gA scope_value_0=(); declare -gA scope_kind_0=()
evaluate "$json" 0
