#!/bin/bash

# This is a test suite for correct index naming
# This test should be run last in the test suite with a
# well populated elasticsearch containing both indices from
# the tests as well as indices from openshift and system logs

source "$(dirname "${BASH_SOURCE[0]}" )/../hack/lib/init.sh"
source "${OS_O_A_L_DIR}/hack/testing/util.sh"
os::util::environment::use_sudo

os::test::junit::declare_suite_start "test/zzz-correct-index-names"

# ensure that _default_, _openshift_, and _openshift-infra_ indices
# are not present in es

# ensure that _default_, _openshift_, and _openshift-infra_ namespace
# records are not present in es

# ensure that _default_, _openshift_, and _openshift-infra_ namespace
# records are present in es-ops

es_pod=$( get_es_pod es )
es_ops_pod=$( get_es_pod es-ops )
es_ops_pod=${es_ops_pod:-$es_pod}

OPS_NAMESPACES="default openshift openshift-infra openshift-this-is-a-test"

# write some logs from namespace openshift and openshift-infra
test_template=$OS_O_A_L_DIR/hack/testing/templates/test-template.yaml

timeout=$(( second * 180 ))
for project in $OPS_NAMESPACES ; do
    delete_project=""
    if oc get project $project 2>&1 | artifact_out ; then
        os::log::debug "use existing project $project"
    else
        os::log::info Creating project $project
        oc adm new-project $project --node-selector='' 2>&1 | artifact_out
        os::cmd::try_until_success "oc get project $project" ${timeout} 2>&1 | artifact_out
        delete_project="$project"
    fi
    message_uuid=$( uuidgen | sed 's/[-]//g' )
    oc process -f $test_template \
        -p TEST_POD_NAME=test-pod \
        -p TEST_POD_MESSAGE="$message_uuid" \
        -p TEST_POD_SLEEP_TIME=1 \
        -p TEST_NAMESPACE_NAME=${project} \
        -p TEST_ITERATIONS=1 | oc create -f - 2>&1 | artifact_out
    os::cmd::try_until_text "oc get -n ${project} pods test-pod" "^test-pod.* Running " ${timeout}
    # The query part will return more than one if successful - due to the fuzzy matching,
    # it may return results from more than one namespace - the jq select will ensure that
    # the namespace name matches exactly
    os::cmd::try_until_text "curl_es $es_ops_pod /.operations.*/_search?q=message:$message_uuid | \
        jq '.hits.hits | map(select(._source.kubernetes.namespace_name == \"${project}\")) | length | . > 0'" "^true\$"  ${timeout}
    oc delete -n ${project} --force pod test-pod 2>&1 | artifact_out
    os::cmd::try_until_failure "oc get -n ${project} pod test-pod" ${timeout}
    if [ -n "$delete_project" ] ; then
        oc delete project $delete_project 2>&1 | artifact_out
        os::cmd::try_until_failure "oc get project $delete_project" ${timeout} 2>&1 | artifact_out
    fi
done

for project in $OPS_NAMESPACES ; do
    qs='{"query":{"term":{"kubernetes.namespace_name":"'"${project}"'"}}}'
    os::cmd::expect_success_and_not_text "curl_es $es_pod /_cat/indices" "project\.${project}\."
    os::cmd::expect_success_and_text "curl_es $es_pod /project.${project}.*/_count | get_count_from_json" "^0\$"
    # since we can't rely on query term to give us an exact match, do that part in jq
    #os::cmd::expect_success_and_text "curl_es $es_pod /project.*/_count -X POST -d '$qs' | get_count_from_json" "^0\$"
    # use large size e.g. a fuzzy search for q=kubernetes.namespace_name:openshift-infra could return 9998
    # hits for kubernetes.namespace_name=openshift and one for openshift-infra
    os::cmd::expect_success_and_text "curl_es $es_pod /project.*/_search?q=kubernetes.namespace_name:${project}\&size=9999 | \
        jq '.hits.hits | map(select(._source.kubernetes.namespace_name == \"${project}\")) | length | . > 0'" "^false\$"
    if [ "$es_pod" != "$es_ops_pod" ] ; then
        os::cmd::expect_success_and_not_text "curl_es $es_ops_pod /_cat/indices" "project\.${project}\."
        os::cmd::expect_success_and_text "curl_es $es_ops_pod /project.${project}.*/_count | get_count_from_json" "^0\$"
        #os::cmd::expect_success_and_text "curl_es $es_ops_pod /project.*/_count -X POST -d '$qs' | get_count_from_json" "^0\$"
        os::cmd::expect_success_and_text "curl_es $es_ops_pod /project.*/_search?q=kubernetes.namespace_name:${project}\&size=9999 | \
            jq '.hits.hits | map(select(._source.kubernetes.namespace_name == \"${project}\")) | length | . > 0'" "^false\$"
    fi
    os::cmd::expect_success_and_text "curl_es $es_ops_pod /.operations.*/_search?q=kubernetes.namespace_name:${project}\&size=9999 | \
        jq '.hits.hits | map(select(._source.kubernetes.namespace_name == \"${project}\")) | length | . > 0'" "^true\$"
done
