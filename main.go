package main

import (
	"k8s.io/klog/v2"
	"os"

	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client/config"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/manager/signals"
	"sigs.k8s.io/controller-runtime/pkg/webhook"
)

var (
	scheme = runtime.NewScheme()
)

func main() {
	// Setup a Manager
	klog.Info("setting up manager")
	mgr, err := manager.New(config.GetConfigOrDie(), manager.Options{
		Scheme:             scheme,
		MetricsBindAddress: "0",
		Port:               9443,
		CertDir:            "/etc/k8s-webhook-server/serving-certs",
	})
	if err != nil {
		klog.Errorf("unable to start manager, error: %v", err)
		os.Exit(-1)
	}

	// Setup webhooks
	klog.Infof("setting up webhook server")
	hookServer := mgr.GetWebhookServer()

	klog.Infof("registering webhooks to the webhook server")
	hookServer.Register("/mutate-pods", &webhook.Admission{Handler: &podMutate{Client: mgr.GetClient()}})

	klog.Infof("starting manager")
	if err := mgr.Start(signals.SetupSignalHandler()); err != nil {
		klog.Errorf("problem running manager, error: %v", err)
		os.Exit(-1)
	}
}
