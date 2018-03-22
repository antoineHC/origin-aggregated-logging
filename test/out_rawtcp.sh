#!/bin/bash

# This is a test suite for the fluentd raw_tcp feature

source "$(dirname "${BASH_SOURCE[0]}" )/../hack/lib/init.sh"
source "${OS_O_A_L_DIR}/hack/testing/util.sh"
os::util::environment::use_sudo

FLUENTD_WAIT_TIME=${FLUENTD_WAIT_TIME:-$(( 2 * minute ))}

os::test::junit::declare_suite_start "test/raw-tcp"

update_current_fluentd() {
    cnt=${FORWARDCNT:-1}
    # this will update it so the current fluentd does not send logs to an ES host
    # but instead forwards to a logsatsh container

    # undeploy fluentd
    os::log::debug "$( oc label node --all logging-infra-fluentd- )"
    os::cmd::try_until_text "oc get daemonset logging-fluentd -o jsonpath='{ .status.numberReady }'" "0" $FLUENTD_WAIT_TIME

    FLUENTD_FORWARD=()
    id=0
    while [ $id -lt $cnt ]; do
      POD=$( oc get pods -l component=forward-fluentd${id} -o name )
      FLUENTD_FORWARD[$id]=$( oc get $POD --template='{{.status.podIP}}' )
      artifact_log update_current_fluentd .status.podIP ${FLUENTD_FORWARD[$id]}
      id=$( expr $id + 1 ) || :
    done

    # update configmap raw-tcp.conf
    if [ $cnt -eq 1 ]; then
      # edit so we don't send to ES
      oc get configmap/logging-fluentd -o yaml | sed '/## matches/ a\
      <match **>\
        @type copy\
        @include configs.d/user/raw-tcp0.conf\
      </match>' | oc replace -f -
        oc patch configmap/logging-fluentd --type=json --patch '[{ "op": "add", "path": "/data/raw-tcp0.conf", "#": "generated config file raw-tcp0.conf" }]' 2>&1
        oc patch configmap/logging-fluentd --type=json --patch '[{ "op": "replace", "path": "/data/raw-tcp0.conf", "value": "\
  <store>\n\
   @type rawtcp\n\
   flush_interval 1\n\
    <server>\n\
      name logstash\n\
      host ${FLUENTD_FORWARD[0]}\n\
      port 9400\n\
    </server>\n\
  </store>\n"}]'
      else
    # edit so we don't send to ES
    oc get configmap/logging-fluentd -o yaml | sed '/## matches/ a\
      <match **>\
        @type copy\
        @include configs.d/user/raw-tcp1.conf\
      </match>' | oc replace -f -
        oc patch configmap/logging-fluentd --type=json --patch '[{ "op": "add", "path": "/data/raw-tcp1.conf", "#": "generated config file raw-tcp1.conf" }]' 2>&1
        oc patch configmap/logging-fluentd --type=json --patch '[{ "op": "replace", "path": "/data/raw-tcp1.conf", "value": "\
  <store>\n\
   @type rawtcp\n\
   flush_interval 1\n\
    <server>\n\
      name logstash\n\
      host ${FLUENTD_FORWARD[0]}\n\
      port 9400\n\
    </server>\n\
  </store>\n\
  <store>\n\
   @type rawtcp\n\
   flush_interval 1\n\
    <server>\n\
      name logstash\n\
      host ${FLUENTD_FORWARD[1]}\n\
      port 9400\n\
    </server>\n\
  </store>\n}]'
      fi

    # redeploy fluentd
    os::cmd::expect_success flush_fluentd_pos_files
    os::log::debug "$( oc label node --all logging-infra-fluentd=true )"
    os::cmd::try_until_text "oc get pods -l component=fluentd" "^logging-fluentd-.* Running "
    artifact_log update_current_fluentd $cnt
    fpod=$( get_running_pod fluentd ) || :
    artifact_log update_current_fluentd $cnt "(oc logs $fpod)"
    if [ -n "${fpod:-}" ] ; then
        oc logs $fpod 2>&1 | artifact_out
        id=$( expr $cnt - 1 ) || :
        artifact_log update_current_fluentd $cnt "(/etc/fluent/configs.d/user/secure-forward${id}.conf)"
        oc exec $fpod -- cat /etc/fluent/configs.d/user/secure-forward${id}.conf | artifact_out || :
        artifact_log update_current_fluentd $cnt "(oc get pods)"
        oc get pods 2>&1 | artifact_out
    fi
}

create_forwarding_fluentd() {
 cnt=${FORWARDCNT:-1}
  id=0
  while [ $id -lt $cnt ]; do

    # create forwarding daemonset
    if [ $id -eq 0 ]; then
       # create forwarding daemonset
      oc create -f $OS_O_A_L_DIR/hack/templates/logstash-ds.yml
      oc get daemonset/logstash -o yaml | \
        sed -e "s/logging-infra-fluentd:/logging-infra-raw-tcp0:/" \
        sed -e "s/component: logstash/component: logstash0:/" \ | \
        oc apply -f -
    else
      oc create -f $OS_O_A_L_DIR/hack/templates/logstash-ds.yml
      oc get daemonset/logstash -o yaml | \
        sed -e "s/logging-infra-fluentd:/logging-infra-raw-tcp1:/" \
        sed -e "s/component: logstash/component: logstash1:/" \ | \
        oc apply -f -
    fi

    os::log::debug "$( oc label node --all logging-infra-raw-tcp${id}=true )"
   
    # wait for forward-fluentd to start
    os::cmd::try_until_text "oc get pods -l component=logging-infra-raw-tcp${id}" "^logging-forward-logstash${id}-.* Running "
    POD=$( oc get pods -l component=forward-fluentd${id} -o name )
    artifact_log create_forwarding_fluentd $cnt "(oc logs $POD)"
    oc logs $POD 2>&1 | artifact_out || :
    id=$( expr $id + 1 )
  done
}

# save current fluentd daemonset
saveds=$( mktemp )
oc get daemonset logging-fluentd -o yaml > $saveds

# save current fluentd configmap
savecm=$( mktemp )
oc get configmap logging-fluentd -o yaml > $savecm

cleanup() {
  local return_code="$?"
  set +e
  if [ $return_code = 0 ] ; then
    mycmd=os::log::info
  else
    mycmd=os::log::error
  fi
  cnt=${FORWARDCNT:-0}
  # dump the pod before we restart it
  if [ -n "${fpod:-}" ] ; then
    artifact_log cleanup "(oc logs $fpod)"
    oc logs $fpod 2>&1 | artifact_out || :
  fi
  oc get pods 2>&1 | artifact_out
  id=0
  while [ $id -lt $cnt ]; do
    POD=$( oc get pods -l component=forward-fluentd${id} -o name ) || :
    artifact_log cleanup $cnt "(oc logs $POD)"
    oc logs $POD 2>&1 | artifact_out || :
    id=$( expr $id + 1 )
  done
  os::log::debug "$( oc label node --all logging-infra-fluentd- 2>&1 || : )"
  os::cmd::try_until_text "oc get daemonset logging-fluentd -o jsonpath='{ .status.numberReady }'" "0" $FLUENTD_WAIT_TIME
  if [ -n "${savecm:-}" -a -f "${savecm:-}" ] ; then
    os::log::debug "$( oc replace --force -f $savecm )"
  fi
  if [ -n "${saveds:-}" -a -f "${saveds:-}" ] ; then
    os::log::debug "$( oc replace --force -f $saveds )"
  fi
  id=0
  while [ $id -lt $cnt ]; do
    $mycmd raw-tcp${id} test finished at $( date )

    # Clean up only if it's still around
    os::log::debug "$( oc delete daemonset/logging-forward-logstash${id} 2>&1 || : )"
    os::log::debug "$( oc delete configmap/logging-forward-logstash${id} 2>&1 || : )"
    os::log::debug "$( oc label node --all logging-infra-forward-fluentd${id}- 2>&1 || : )"
    id=$( expr $id + 1 )
  done
  os::cmd::expect_success flush_fluentd_pos_files
  os::log::debug "$( oc label node --all logging-infra-fluentd=true 2>&1 || : )"
  if [ $cnt -gt 1 ]; then
    cat $extra_artifacts
    # this will call declare_test_end, suite_end, etc.
    os::test::junit::reconcile_output
    exit $return_code
  fi
}
trap "cleanup" EXIT

os::log::info Starting raw-tcp test at $( date )

# make sure fluentd is working normally
os::cmd::try_until_text "oc get pods -l component=fluentd" "^logging-fluentd-.* Running "
fpod=$( get_running_pod fluentd )
os::cmd::expect_success wait_for_fluentd_to_catch_up

# FORWARDCNT must be 1 or 2
FORWARDCNT=1
create_forwarding_fluentd
update_current_fluentd
os::cmd::expect_success wait_for_fluentd_to_catch_up
cleanup

FORWARDCNT=2
create_forwarding_fluentd
update_current_fluentd
os::cmd::expect_success "wait_for_fluentd_to_catch_up '' '' 2"
