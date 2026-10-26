/**
# Copyright (c) NVIDIA CORPORATION.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
**/

package state

import (
	"context"
	"fmt"
	"maps"
	"net"
	"strconv"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	nvidiav1 "github.com/NVIDIA/gpu-operator/api/nvidia/v1"
	nvidiav1alpha1 "github.com/NVIDIA/gpu-operator/api/nvidia/v1alpha1"
	"github.com/NVIDIA/gpu-operator/internal/image"
)

const (
	// draDriverImageEnvName is the fallback env var for the DRA driver image when the
	// CR does not specify repository/image/version.
	draDriverImageEnvName = "DRA_DRIVER_IMAGE"
	// draValidatorImageEnvName is the env var for the gpu-operator image that ships the
	// nvidia-validator binary used by the kubelet-plugin driver-validation init container.
	draValidatorImageEnvName = "VALIDATOR_IMAGE"

	// Default gRPC health service ports of the kubelet-plugin containers, matching the
	// upstream k8s-dra-driver-gpu Helm chart.
	defaultGPUsHealthcheckPort           = int32(51516)
	defaultComputeDomainsHealthcheckPort = int32(51515)

	// Metrics endpoints of the kubelet-plugin containers, mirroring the
	// HTTP_ENDPOINT values in manifests/state-dra-driver/0500_daemonset.yaml.
	gpusMetricsEndpoint           = ":8080"
	computeDomainsMetricsEndpoint = ":8081"
	// defaultMetricsPath mirrors the METRICS_PATH value the template renders for
	// both kubelet-plugin containers.
	defaultMetricsPath = "/metrics"
)

// reservedKubeletPluginEnv lists the environment variables kubeletPlugin.env must
// not set. The probes take the health service port from the healthcheck.port
// field, so a HEALTHCHECK_PORT override would move the service away from its
// probes. HTTP_ENDPOINT is not reserved: moving the metrics listener works, and
// validateKubeletPluginPorts checks the port it resolves to.
var reservedKubeletPluginEnv = []string{"HEALTHCHECK_PORT"}

// resolveHealthcheckPort returns the spec-provided health service port, or the
// container's default when unset; -1 (disabled) omits the probes at render time.
func resolveHealthcheckPort(hc *nvidiav1alpha1.DRADriverHealthcheckSpec, defaultPort int32) int32 {
	if hc != nil && hc.Enabled != nil && !*hc.Enabled {
		return -1
	}
	if hc != nil && hc.Port != nil {
		return *hc.Port
	}
	return defaultPort
}

// lastEnvValue returns the value written for name in kubeletPlugin.env, or
// defaultValue when it is not set. The entries are rendered after the template's
// own and the kubelet keeps the last value for a duplicated name, so the last
// matching entry wins.
func lastEnvValue(env []nvidiav1.EnvVar, name, defaultValue string) string {
	value := defaultValue
	for _, e := range env {
		if e.Name == name {
			value = e.Value
		}
	}
	return value
}

// expandEnvValue expands the $(VAR) references in an env value the way the
// kubelet does before starting the container (the expansion rules of
// k8s.io/kubernetes/third_party/forked/golang/expansion): $(NAME) becomes
// vars[NAME] when NAME is defined and stays as written when it is not, $$
// becomes a single $, and a $ followed by anything else is kept as written.
func expandEnvValue(value string, vars map[string]string) string {
	var out strings.Builder
	for i := 0; i < len(value); i++ {
		if value[i] != '$' || i+1 >= len(value) {
			out.WriteByte(value[i])
			continue
		}
		switch value[i+1] {
		case '$':
			out.WriteByte('$')
			i++
		case '(':
			end := strings.IndexByte(value[i+2:], ')')
			if end < 0 {
				out.WriteByte('$')
				continue
			}
			name := value[i+2 : i+2+end]
			if v, ok := vars[name]; ok {
				out.WriteString(v)
			} else {
				out.WriteString("$(" + name + ")")
			}
			i += 2 + end
		default:
			out.WriteByte('$')
		}
	}
	return out.String()
}

// containerEnv returns the variables a kubelet-plugin container will see, by
// name, after the kubelet's expansion. The kubelet expands each entry against
// the variables defined before it in the same container, so base holds the
// template's variables that precede kubeletPlugin.env and whose values are
// known here; the user's entries follow in order, each expanded against
// everything before it, and a later entry overrides an earlier one of the same
// name. Template variables outside base (the node name, the kubelet paths) are
// left as unexpanded references.
func containerEnv(base map[string]string, env []nvidiav1.EnvVar) map[string]string {
	vars := make(map[string]string, len(base)+len(env))
	maps.Copy(vars, base)
	for _, e := range env {
		vars[e.Name] = expandEnvValue(e.Value, vars)
	}
	return vars
}

// metricsAddress returns the address a kubelet-plugin container's metrics server
// will bind, as a listener without a name, and the HTTP_ENDPOINT it resolves from,
// given the container's expanded env. The port is 0 when no server binds: the
// plugin starts it only when both HTTP_ENDPOINT and METRICS_PATH are non-empty. It
// is also 0 when the port cannot be resolved here: a port still holding a $(VAR)
// reference, which the kubelet may resolve from a variable this validation does
// not know or leave literal for the plugin to fail on, or a service name this
// process does not know. Neither can be proven either way, so the listener is not
// checked. A reference in the host alone does not hide the port: whatever the
// host becomes, the server binds that port on some local address or fails, so the
// listener is kept with hostKnown false. The port is resolved as net.Listen would,
// so a service name such as "http" counts as 80. The host is "" when the server
// listens on every address.
func metricsAddress(vars map[string]string) (listener, string, error) {
	endpoint := vars["HTTP_ENDPOINT"]
	if endpoint == "" || vars["METRICS_PATH"] == "" {
		return listener{}, endpoint, nil
	}
	host, p, err := net.SplitHostPort(endpoint)
	if err != nil {
		if strings.Contains(endpoint, "$(") {
			// The reference may supply the separator; nothing is provable.
			return listener{}, endpoint, nil
		}
		return listener{}, endpoint, fmt.Errorf("HTTP_ENDPOINT %q is not a host:port address: %w", endpoint, err)
	}
	if strings.Contains(p, "$(") {
		return listener{}, endpoint, nil
	}
	// A numeric port outside the TCP range cannot bind in any image, so it is
	// rejected here rather than left for the plugin. net.Listen accepts a service
	// name for the port (":http" is port 80), so a name is resolved the same way;
	// one this process cannot resolve is not proven unknown to the plugin, whose
	// image carries its own services table, so such a listener is not checked.
	if isDigits(p) {
		if _, err := strconv.ParseUint(p, 10, 16); err != nil {
			return listener{}, endpoint, fmt.Errorf("HTTP_ENDPOINT %q port must be between 0 and 65535", endpoint)
		}
	}
	port, err := net.LookupPort("tcp", p)
	if err != nil {
		return listener{}, endpoint, nil
	}
	if strings.Contains(host, "$(") {
		return listener{host: host, hostKnown: false, port: int32(port)}, endpoint, nil
	}
	return listener{host: listenHost(host), hostKnown: true, port: int32(port)}, endpoint, nil
}

// listenHost normalizes the host part of a listen address for comparison. An
// empty host and an unspecified IP (0.0.0.0, ::) both mean every address and
// become ""; any other IP literal takes its canonical form, so the spellings of
// one address compare equal ([::1] and [0:0:0:0:0:0:0:1]) and an IPv4-mapped
// IPv6 address matches the IPv4 address it binds (net.Listen binds
// [::ffff:127.0.0.1] as 127.0.0.1); a hostname is compared as written.
func listenHost(host string) string {
	ip := net.ParseIP(host)
	switch {
	case ip == nil:
		return host
	case ip.IsUnspecified():
		return ""
	default:
		return ip.String()
	}
}

// isDigits reports whether s is non-empty and all ASCII digits: a port written
// as a number rather than a service name.
func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// listener is one TCP listen address of a kubelet-plugin container.
type listener struct {
	name      string
	host      string // "" listens on every address
	hostKnown bool   // false: host is a $(VAR) reference the kubelet expands later
	port      int32
}

// conflicts reports whether two listeners cannot both bind. The ports must match;
// then one listening on every address takes the port on every host, while two
// specific hosts collide only when they are the same. Two metrics servers on
// distinct addresses of one port therefore coexist. A host that is not known
// here collides with a wildcard like any other host, but its equality with
// another specific host cannot be proven, so that pair is let through.
func (l listener) conflicts(o listener) bool {
	if l.port != o.port {
		return false
	}
	if l.host == "" || o.host == "" {
		return true
	}
	return l.hostKnown && o.hostKnown && l.host == o.host
}

// validateKubeletPluginPorts rejects a GPUCluster whose kubelet-plugin containers
// would bind the same TCP address twice. Every listener in the pod, health services
// and metrics endpoints alike, shares one network namespace, so the second bind
// fails with EADDRINUSE and that container crash-loops; between containers, which
// one loses is a startup race. The check runs on resolved health ports so a user
// who sets only one port to the other container's default is caught too, and on
// the address each container's metrics env resolves to, after the $(VAR) expansion
// the kubelet applies (see containerEnv). The health services always
// listen on every address, so they collide with any listener on their port; metrics
// endpoints on distinct specific addresses may share a port (see listener.conflicts).
// A port <= 0 never binds: a disabled health service, a disabled metrics server, or
// port 0, which the kernel replaces with a free one.
func validateKubeletPluginPorts(computeDomainsEnabled bool, gpusPort, computeDomainsPort int32,
	gpusEnv, computeDomainsEnv []nvidiav1.EnvVar) error {
	type container struct {
		name            string
		field           string
		env             []nvidiav1.EnvVar
		defaultEndpoint string
		healthPort      int32
	}
	containers := []container{
		{"gpus", "spec.draDriver.gpus", gpusEnv, gpusMetricsEndpoint, gpusPort},
	}
	if computeDomainsEnabled {
		containers = append(containers, container{"compute-domains", "spec.draDriver.computeDomains",
			computeDomainsEnv, computeDomainsMetricsEndpoint, computeDomainsPort})
	}

	var listeners []listener
	for _, c := range containers {
		// The template renders these ahead of kubeletPlugin.env, so an entry may
		// reference them; HEALTHCHECK_PORT carries the resolved port, as rendered.
		vars := containerEnv(map[string]string{
			"HTTP_ENDPOINT":    c.defaultEndpoint,
			"METRICS_PATH":     defaultMetricsPath,
			"HEALTHCHECK_PORT": strconv.Itoa(int(c.healthPort)),
		}, c.env)
		metrics, endpoint, err := metricsAddress(vars)
		if err != nil {
			return fmt.Errorf("%s.kubeletPlugin.env: %w", c.field, err)
		}
		metrics.name = fmt.Sprintf("the %s container metrics endpoint (HTTP_ENDPOINT %q)", c.name, endpoint)
		if written := lastEnvValue(c.env, "HTTP_ENDPOINT", c.defaultEndpoint); written != endpoint {
			metrics.name = fmt.Sprintf("the %s container metrics endpoint (HTTP_ENDPOINT %q, expanded to %q)", c.name, written, endpoint)
		}
		listeners = append(listeners,
			metrics,
			listener{name: c.field + ".kubeletPlugin.healthcheck.port", host: "", hostKnown: true, port: c.healthPort},
		)
	}

	for i, l := range listeners {
		if l.port <= 0 {
			continue
		}
		for _, prev := range listeners[:i] {
			if prev.port > 0 && prev.conflicts(l) {
				return fmt.Errorf("%s and %s must differ; both resolve to %d", prev.name, l.name, l.port)
			}
		}
	}
	return nil
}

// validateKubeletPluginEnv rejects a GPUCluster whose kubeletPlugin.env sets a
// reserved variable (see reservedKubeletPluginEnv). The gpus container is always
// rendered; the compute-domains container only when enabled, so its env is only
// checked then.
func validateKubeletPluginEnv(computeDomainsEnabled bool, gpusEnv, computeDomainsEnv []nvidiav1.EnvVar) error {
	type envList struct {
		field string
		env   []nvidiav1.EnvVar
	}
	lists := []envList{{"spec.draDriver.gpus.kubeletPlugin.env", gpusEnv}}
	if computeDomainsEnabled {
		lists = append(lists, envList{"spec.draDriver.computeDomains.kubeletPlugin.env", computeDomainsEnv})
	}

	for _, l := range lists {
		for _, e := range l.env {
			for _, reserved := range reservedKubeletPluginEnv {
				if e.Name == reserved {
					return fmt.Errorf("%s must not set %s; it is managed by the operator "+
						"(use the healthcheck.port field for the health service port)", l.field, reserved)
				}
			}
		}
	}
	return nil
}

type stateDRADriver struct {
	stateSkel
}

var _ State = (*stateDRADriver)(nil)

func NewStateDRADriver(
	k8sClient client.Client,
	namespace string,
	scheme *runtime.Scheme,
	manifestDir string) (State, error) {

	skel, err := newStateSkel(k8sClient, namespace, scheme, manifestDir,
		"state-dra-driver", "NVIDIA DRA driver deployed in the cluster")
	if err != nil {
		return nil, err
	}
	return &stateDRADriver{stateSkel: skel}, nil
}

func (s *stateDRADriver) Sync(ctx context.Context, customResource any, infoCatalog InfoCatalog) (SyncState, error) {
	cr, ok := customResource.(*nvidiav1alpha1.GPUCluster)
	if !ok {
		return SyncStateError, fmt.Errorf("GPUCluster CR not provided as input to Sync()")
	}

	objs, err := s.getManifestObjects(ctx, cr, infoCatalog)
	if err != nil {
		return SyncStateNotReady, fmt.Errorf("failed to create k8s objects from manifests: %w", err)
	}

	if len(objs) == 0 {
		// The gpus capability renders unconditionally, so an empty render indicates a
		// bug (e.g. missing manifests); surface it rather than reporting ready.
		return SyncStateNotReady, fmt.Errorf("no objects rendered for the DRA driver state")
	}

	return s.syncObjects(ctx, cr, objs)
}

func (s *stateDRADriver) GetWatchSources(mgr ctrlManager) map[string]SyncingSource {
	return gpuClusterDaemonSetSource(mgr)
}

func (s *stateDRADriver) getManifestObjects(ctx context.Context, cr *nvidiav1alpha1.GPUCluster, infoCatalog InfoCatalog) ([]*unstructured.Unstructured, error) {
	apiVersion, err := draResourceAPIVersion(infoCatalog)
	if err != nil {
		return nil, fmt.Errorf("failed to get DRA resource apiVersion: %w", err)
	}

	draDriverSpec, err := getDRADriverSpec(&cr.Spec.DRADriver)
	if err != nil {
		return nil, fmt.Errorf("failed to construct DRA driver spec: %w", err)
	}

	hostPaths := cr.Spec.HostPaths
	daemonsets := cr.Spec.Daemonsets
	openshiftVersion, err := clusterOpenshiftVersion(infoCatalog)
	if err != nil {
		return nil, fmt.Errorf("failed to get OpenShift version: %w", err)
	}

	gpusHealthcheckPort := resolveHealthcheckPort(
		cr.Spec.DRADriver.GPUs.KubeletPlugin.Healthcheck, defaultGPUsHealthcheckPort)
	computeDomainsHealthcheckPort := resolveHealthcheckPort(
		cr.Spec.DRADriver.ComputeDomains.KubeletPlugin.Healthcheck, defaultComputeDomainsHealthcheckPort)
	if err := validateKubeletPluginPorts(cr.Spec.DRADriver.IsComputeDomainsEnabled(),
		gpusHealthcheckPort, computeDomainsHealthcheckPort,
		cr.Spec.DRADriver.GPUs.KubeletPlugin.Env, cr.Spec.DRADriver.ComputeDomains.KubeletPlugin.Env); err != nil {
		return nil, fmt.Errorf("invalid DRA driver kubelet-plugin port configuration: %w", err)
	}
	if err := validateKubeletPluginEnv(cr.Spec.DRADriver.IsComputeDomainsEnabled(),
		cr.Spec.DRADriver.GPUs.KubeletPlugin.Env, cr.Spec.DRADriver.ComputeDomains.KubeletPlugin.Env); err != nil {
		return nil, fmt.Errorf("invalid DRA driver kubelet-plugin env configuration: %w", err)
	}

	renderData := &draDriverRenderData{
		DRADriver:                     draDriverSpec,
		HostPaths:                     &hostPaths,
		Daemonsets:                    &daemonsets,
		Namespace:                     s.namespace,
		OpenshiftVersion:              openshiftVersion,
		DeviceClassAPIVersion:         apiVersion,
		FeatureGates:                  cr.Spec.DRADriver.FeatureGates,
		GPUsHealthcheckPort:           gpusHealthcheckPort,
		ComputeDomainsHealthcheckPort: computeDomainsHealthcheckPort,
	}

	return s.renderObjects(ctx, renderData)
}

// getDRADriverSpec builds the render-time DRA driver spec, resolving the DRA driver
// image (from the CR, falling back to DRA_DRIVER_IMAGE) and the init-container image
// (the gpu-operator image carrying nvidia-validator, from VALIDATOR_IMAGE).
func getDRADriverSpec(spec *nvidiav1alpha1.DRADriverSpec) (*draDriverSpec, error) {
	imagePath, err := image.ImagePath(spec.Repository, spec.Image, spec.Version, draDriverImageEnvName)
	if err != nil {
		return nil, fmt.Errorf("failed to construct DRA driver image path: %w", err)
	}

	initImagePath, err := image.ImagePath("", "", "", draValidatorImageEnvName)
	if err != nil {
		return nil, fmt.Errorf("failed to construct DRA driver validator image path: %w", err)
	}

	resourceRequirements := []*nvidiav1.ResourceRequirements{
		spec.GPUs.KubeletPlugin.Resources,
	}
	if spec.IsComputeDomainsEnabled() {
		resourceRequirements = append(resourceRequirements, spec.ComputeDomains.KubeletPlugin.Resources)
	}

	return &draDriverSpec{
		Spec:                   spec,
		ImagePath:              imagePath,
		InitImagePath:          initImagePath,
		InitContainerResources: maxResourceRequirements(resourceRequirements...),
	}, nil
}

func maxResourceRequirements(requirements ...*nvidiav1.ResourceRequirements) *nvidiav1.ResourceRequirements {
	result := &nvidiav1.ResourceRequirements{}

	for _, requirement := range requirements {
		if requirement == nil {
			continue
		}
		result.Requests = maxResourceList(result.Requests, requirement.Requests)
		result.Limits = maxResourceList(result.Limits, requirement.Limits)
	}

	// A request-only container can have a larger request than another container's
	// explicit limit. Keep the merged requirement valid without adding limits for
	// resources that were unbounded in every source container.
	for name, request := range result.Requests {
		limit, ok := result.Limits[name]
		if ok && request.Cmp(limit) > 0 {
			result.Limits[name] = request.DeepCopy()
		}
	}

	if len(result.Requests) == 0 && len(result.Limits) == 0 {
		return nil
	}
	return result
}

func maxResourceList(resourceLists ...corev1.ResourceList) corev1.ResourceList {
	var result corev1.ResourceList

	for _, resourceList := range resourceLists {
		for name, quantity := range resourceList {
			current, ok := result[name]
			if ok && quantity.Cmp(current) <= 0 {
				continue
			}
			if result == nil {
				result = corev1.ResourceList{}
			}
			result[name] = quantity.DeepCopy()
		}
	}

	return result
}
