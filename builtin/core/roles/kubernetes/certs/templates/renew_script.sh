#!/bin/bash
set -euo pipefail

# kubekey v4 supports kubernetes >= v1.23, so kubeadm certs subcommand is always available.
kubeadmCerts='/usr/local/bin/kubeadm certs'

# Return the smallest residual days among all kubeadm-managed certificates.
# Uses the "RESIDUAL TIME" column from "kubeadm certs check-expiration" (e.g. "364d").
# Falls back to 9999 (skip renewal) when parsing fails, so the timer never renew-spams.
getCertValidDays() {
  local days
  days=$(${kubeadmCerts} check-expiration 2>/dev/null | grep -oE '[0-9]+d' | grep -oE '[0-9]+' | sort -n | head -1)
  if [ -z "${days}" ]; then
    days=9999
  fi
  echo -n "${days}"
}

echo "## Expiration before renewal ##"
${kubeadmCerts} check-expiration

if [ "$(getCertValidDays)" -lt 30 ]; then
  echo "## Renewing certificates managed by kubeadm ##"
  ${kubeadmCerts} renew all

  echo "## Restarting control plane pods managed by kubeadm ##"
  $(which crictl | grep crictl) pods --namespace kube-system --name 'kube-scheduler-*|kube-controller-manager-*|kube-apiserver-*|etcd-*' -q | /usr/bin/xargs $(which crictl | grep crictl) rmp -f

  echo "## Updating /root/.kube/config ##"
  cp /etc/kubernetes/admin.conf /root/.kube/config
fi

echo "## Waiting for apiserver to be up again ##"
until printf "" 2>>/dev/null >>/dev/tcp/127.0.0.1/6443; do sleep 1; done

echo "## Expiration after renewal ##"
${kubeadmCerts} check-expiration
