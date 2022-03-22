package main

import (
	"context"
	"encoding/json"
	"k8s.io/klog/v2"
	"net/http"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

const (
	teamLabelKey = "cicd.devel/team"
	teamWe       = "we"
	teamOthers   = "others"
)

var tcosAnnotationsKeywords = []string{
	"tos-auto-build",
}

var tcosImagesKeywords = []string{
	"kube-build-base",
}

type podMutate struct {
	Client  client.Client
	decoder *admission.Decoder
}

func (p *podMutate) Handle(ctx context.Context, req admission.Request) admission.Response {
	pod := &corev1.Pod{}

	err := p.decoder.Decode(req, pod)
	if err != nil {
		klog.Errorf("failed decoder pod, error: %v", err)
		return admission.Errored(http.StatusBadRequest, err)
	}
	klog.Infof("Try to handle pod: %s/%s", pod.Namespace, pod.Name)

	// eg: pod.Annotations["buildUrl"] = "http://172.26.0.7:30237/job/tos-auto-build/job/r/job/master/45/"
	buildURL, ok := pod.Annotations["buildUrl"]
	if ok {
		for _, k := range tcosAnnotationsKeywords {
			if strings.Contains(buildURL, k) {
				pod.Spec.NodeSelector[teamLabelKey] = teamWe
				klog.Infof("NodeSelector pod %s/%s to label %s=%s", pod.Namespace, pod.Name, teamLabelKey, pod.Spec.NodeSelector[teamLabelKey])
				return returnWrapper(req, pod)
			}
		}
	}

	for _, c := range pod.Spec.Containers {
		// eg: 172.16.1.99/tostmp/kube-build-base:latest
		for _, s := range tcosImagesKeywords {
			if strings.Contains(c.Image, s) {
				pod.Spec.NodeSelector[teamLabelKey] = teamWe
				klog.Infof("NodeSelector pod %s/%s to label %s=%s", pod.Namespace, pod.Name, teamLabelKey, pod.Spec.NodeSelector[teamLabelKey])
				return returnWrapper(req, pod)
			}
		}
	}

	pod.Spec.NodeSelector[teamLabelKey] = teamOthers
	klog.Infof("NodeSelector pod %s/%s to label %s=%s", pod.Namespace, pod.Name, teamLabelKey, pod.Spec.NodeSelector[teamLabelKey])
	return returnWrapper(req, pod)
}

func returnWrapper(req admission.Request, pod interface{}) admission.Response {
	marshaledPod, err := json.Marshal(pod)
	if err != nil {
		klog.Errorf("failed marshal pod, error: %v", err)
		return admission.Errored(http.StatusInternalServerError, err)
	}
	return admission.PatchResponseFromRaw(req.Object.Raw, marshaledPod)
}

// podMutate implements admission.DecoderInjector.
// A decoder will be automatically injected.

// InjectDecoder injects the decoder.
func (p *podMutate) InjectDecoder(d *admission.Decoder) error {
	p.decoder = d
	return nil
}
