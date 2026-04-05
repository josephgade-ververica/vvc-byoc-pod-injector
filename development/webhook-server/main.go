package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"gopkg.in/yaml.v3"
)

// ═══════════════════════════════════════════════════════════════════════════
//  Configuration schema — loaded from ConfigMap YAML
// ═══════════════════════════════════════════════════════════════════════════

type InjectionConfig struct {
	Targeting TargetingConfig  `yaml:"targeting" json:"targeting"`
	EnvVars   []EnvVarConfig   `yaml:"envVars" json:"envVars"`
	Volumes   []VolumeConfig   `yaml:"volumes" json:"volumes"`
	InitContainers []InitContainerConfig `yaml:"initContainers,omitempty" json:"initContainers,omitempty"`
}

type TargetingConfig struct {
	Labels map[string]string `yaml:"labels" json:"labels"`
}

type EnvVarConfig struct {
	Name      string `yaml:"name" json:"name"`           // env var name in pod
	Secret    string `yaml:"secret" json:"secret"`       // K8s Secret name
	Key       string `yaml:"key" json:"key"`             // key within the Secret
}

type VolumeConfig struct {
	Name      string `yaml:"name" json:"name"`           // volume name
	Type      string `yaml:"type" json:"type"`           // "secret" or "configmap"
	Source    string `yaml:"source" json:"source"`       // K8s Secret/ConfigMap name
	MountPath string `yaml:"mountPath" json:"mountPath"` // mount path in container
	ReadOnly  bool   `yaml:"readOnly" json:"readOnly"`
	SubPath   string `yaml:"subPath,omitempty" json:"subPath,omitempty"` // optional subPath
}

type InitContainerConfig struct {
	Name    string            `yaml:"name" json:"name"`
	Image   string            `yaml:"image" json:"image"`
	Command []string          `yaml:"command" json:"command"`
	Args    []string          `yaml:"args,omitempty" json:"args,omitempty"`
	Env     []EnvVarConfig    `yaml:"env,omitempty" json:"env,omitempty"`
	Mounts  []string          `yaml:"mounts,omitempty" json:"mounts,omitempty"` // volume names to mount
}

// ═══════════════════════════════════════════════════════════════════════════
//  Global state
// ═══════════════════════════════════════════════════════════════════════════

var (
	config     InjectionConfig
	configLock sync.RWMutex
	configPath = getEnv("CONFIG_PATH", "/config/injection-config.yaml")
	tlsCert    = getEnv("TLS_CERT_FILE", "/tls/tls.crt")
	tlsKey     = getEnv("TLS_KEY_FILE", "/tls/tls.key")
	listenAddr = getEnv("LISTEN_ADDR", ":8443")
	annotationKey = "vvc-byoc-pod-injector.ververica.com/injected"
)

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" { return v }
	return fallback
}

// ═══════════════════════════════════════════════════════════════════════════
//  Main
// ═══════════════════════════════════════════════════════════════════════════

func main() {
	log.Println("═══ vvc-byoc-pod-injector ═══")

	if err := loadConfig(); err != nil {
		log.Fatalf("Failed to load config from %s: %v", configPath, err)
	}

	logConfig()

	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", handleMutate)
	mux.HandleFunc("/healthz", handleHealthz)
	mux.HandleFunc("/config", handleShowConfig)

	cert, err := tls.LoadX509KeyPair(tlsCert, tlsKey)
	if err != nil {
		log.Fatalf("Failed to load TLS: %v", err)
	}

	server := &http.Server{
		Addr:    listenAddr,
		Handler: mux,
		TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}},
	}

	log.Printf("Listening on %s", listenAddr)
	if err := server.ListenAndServeTLS("", ""); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

// ═══════════════════════════════════════════════════════════════════════════
//  Config loading
// ═══════════════════════════════════════════════════════════════════════════

func loadConfig() error {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("read config: %w", err)
	}

	var cfg InjectionConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return fmt.Errorf("parse config: %w", err)
	}

	// Validate
	if len(cfg.Targeting.Labels) == 0 {
		return fmt.Errorf("targeting.labels is required")
	}

	configLock.Lock()
	config = cfg
	configLock.Unlock()

	log.Printf("Config loaded: %d envVars, %d volumes, %d initContainers",
		len(cfg.EnvVars), len(cfg.Volumes), len(cfg.InitContainers))
	return nil
}

func logConfig() {
	configLock.RLock()
	defer configLock.RUnlock()

	log.Printf("Targeting labels:")
	for k, v := range config.Targeting.Labels {
		log.Printf("  %s=%s", k, v)
	}
	for _, ev := range config.EnvVars {
		log.Printf("EnvVar: %s <- %s/%s", ev.Name, ev.Secret, ev.Key)
	}
	for _, vol := range config.Volumes {
		log.Printf("Volume: %s (%s:%s) -> %s", vol.Name, vol.Type, vol.Source, vol.MountPath)
	}
	for _, ic := range config.InitContainers {
		log.Printf("InitContainer: %s (image: %s)", ic.Name, ic.Image)
	}
}

// ═══════════════════════════════════════════════════════════════════════════
//  HTTP handlers
// ═══════════════════════════════════════════════════════════════════════════

func handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

func handleShowConfig(w http.ResponseWriter, r *http.Request) {
	configLock.RLock()
	defer configLock.RUnlock()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(config)
}

func handleMutate(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read body failed", http.StatusBadRequest)
		return
	}

	var review admissionv1.AdmissionReview
	if err := json.Unmarshal(body, &review); err != nil {
		http.Error(w, "unmarshal failed", http.StatusBadRequest)
		return
	}

	resp := mutate(review.Request)
	resp.UID = review.Request.UID
	review.Response = resp

	out, _ := json.Marshal(review)
	w.Header().Set("Content-Type", "application/json")
	w.Write(out)
}

// ═══════════════════════════════════════════════════════════════════════════
//  Mutation logic — fully driven by config
// ═══════════════════════════════════════════════════════════════════════════

func mutate(req *admissionv1.AdmissionRequest) *admissionv1.AdmissionResponse {
	var pod corev1.Pod
	if err := json.Unmarshal(req.Object.Raw, &pod); err != nil {
		log.Printf("ERROR unmarshal pod: %v", err)
		return allow("unmarshal failed")
	}

	podName := pod.Name
	if podName == "" { podName = pod.GenerateName }

	configLock.RLock()
	cfg := config
	configLock.RUnlock()

	if !shouldInject(&pod, cfg.Targeting) {
		return allow("no matching labels")
	}

	if isAlreadyInjected(&pod) {
		return allow("already injected")
	}

	log.Printf("Injecting into %s/%s (%d envVars, %d volumes, %d initContainers)",
		req.Namespace, podName, len(cfg.EnvVars), len(cfg.Volumes), len(cfg.InitContainers))

	patches := buildPatches(&pod, &cfg)
	patchBytes, _ := json.Marshal(patches)
	pt := admissionv1.PatchTypeJSONPatch

	return &admissionv1.AdmissionResponse{
		Allowed:   true,
		PatchType: &pt,
		Patch:     patchBytes,
	}
}

func shouldInject(pod *corev1.Pod, targeting TargetingConfig) bool {
	if pod.Labels == nil { return false }
	for k, v := range targeting.Labels {
		if podVal, ok := pod.Labels[k]; !ok || (v != "*" && podVal != v) {
			return false
		}
	}
	return true
}

func isAlreadyInjected(pod *corev1.Pod) bool {
	if pod.Annotations == nil { return false }
	_, ok := pod.Annotations[annotationKey]
	return ok
}

// ═══════════════════════════════════════════════════════════════════════════
//  Patch building — generic, config-driven
// ═══════════════════════════════════════════════════════════════════════════

type jsonPatch struct {
	Op    string      `json:"op"`
	Path  string      `json:"path"`
	Value interface{} `json:"value,omitempty"`
}

func buildPatches(pod *corev1.Pod, cfg *InjectionConfig) []jsonPatch {
	var patches []jsonPatch

	// ─── Ensure arrays exist ─────────────────────────────────────────
	if pod.Spec.Volumes == nil {
		patches = append(patches, jsonPatch{Op: "add", Path: "/spec/volumes", Value: []interface{}{}})
	}

	// ─── Volumes from config ─────────────────────────────────────────
	for _, vol := range cfg.Volumes {
		var volSource corev1.VolumeSource
		switch strings.ToLower(vol.Type) {
		case "secret":
			volSource = corev1.VolumeSource{
				Secret: &corev1.SecretVolumeSource{SecretName: vol.Source},
			}
		case "configmap":
			volSource = corev1.VolumeSource{
				ConfigMap: &corev1.ConfigMapVolumeSource{
					LocalObjectReference: corev1.LocalObjectReference{Name: vol.Source},
				},
			}
		default:
			log.Printf("WARN: unknown volume type %q for %s, skipping", vol.Type, vol.Name)
			continue
		}
		patches = append(patches, jsonPatch{
			Op: "add", Path: "/spec/volumes/-",
			Value: corev1.Volume{Name: vol.Name, VolumeSource: volSource},
		})
	}

	// ─── InitContainers from config ──────────────────────────────────
	if len(cfg.InitContainers) > 0 {
		// Add emptyDir for initContainer output
		patches = append(patches, jsonPatch{
			Op: "add", Path: "/spec/volumes/-",
			Value: corev1.Volume{
				Name:         "injector-workdir",
				VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
			},
		})

		if pod.Spec.InitContainers == nil {
			patches = append(patches, jsonPatch{Op: "add", Path: "/spec/initContainers", Value: []interface{}{}})
		}

		for _, ic := range cfg.InitContainers {
			container := corev1.Container{
				Name:    ic.Name,
				Image:   ic.Image,
				Command: ic.Command,
				Args:    ic.Args,
			}

			// Env vars for initContainer
			for _, ev := range ic.Env {
				container.Env = append(container.Env, corev1.EnvVar{
					Name: ev.Name,
					ValueFrom: &corev1.EnvVarSource{
						SecretKeyRef: &corev1.SecretKeySelector{
							LocalObjectReference: corev1.LocalObjectReference{Name: ev.Secret},
							Key:                  ev.Key,
						},
					},
				})
			}

			// Mount referenced volumes
			for _, mountName := range ic.Mounts {
				for _, vol := range cfg.Volumes {
					if vol.Name == mountName {
						container.VolumeMounts = append(container.VolumeMounts, corev1.VolumeMount{
							Name: vol.Name, MountPath: vol.MountPath, ReadOnly: vol.ReadOnly,
						})
					}
				}
			}

			// Always mount workdir
			container.VolumeMounts = append(container.VolumeMounts, corev1.VolumeMount{
				Name: "injector-workdir", MountPath: "/work",
			})

			patches = append(patches, jsonPatch{
				Op: "add", Path: "/spec/initContainers/-", Value: container,
			})
		}
	}

	// ─── Inject into ALL containers ──────────────────────────────────
	for i := range pod.Spec.Containers {
		cp := fmt.Sprintf("/spec/containers/%d", i)

		// Env vars
		if len(cfg.EnvVars) > 0 {
			if pod.Spec.Containers[i].Env == nil {
				patches = append(patches, jsonPatch{Op: "add", Path: cp + "/env", Value: []interface{}{}})
			}
			for _, ev := range cfg.EnvVars {
				patches = append(patches, jsonPatch{
					Op: "add", Path: cp + "/env/-",
					Value: corev1.EnvVar{
						Name: ev.Name,
						ValueFrom: &corev1.EnvVarSource{
							SecretKeyRef: &corev1.SecretKeySelector{
								LocalObjectReference: corev1.LocalObjectReference{Name: ev.Secret},
								Key:                  ev.Key,
							},
						},
					},
				})
			}
		}

		// Volume mounts
		if len(cfg.Volumes) > 0 {
			if pod.Spec.Containers[i].VolumeMounts == nil {
				patches = append(patches, jsonPatch{Op: "add", Path: cp + "/volumeMounts", Value: []interface{}{}})
			}
			for _, vol := range cfg.Volumes {
				vm := corev1.VolumeMount{
					Name: vol.Name, MountPath: vol.MountPath, ReadOnly: vol.ReadOnly,
				}
				if vol.SubPath != "" {
					vm.SubPath = vol.SubPath
				}
				patches = append(patches, jsonPatch{
					Op: "add", Path: cp + "/volumeMounts/-", Value: vm,
				})
			}
		}
	}

	// ─── Annotation ──────────────────────────────────────────────────
	if pod.Annotations == nil {
		patches = append(patches, jsonPatch{Op: "add", Path: "/metadata/annotations", Value: map[string]string{}})
	}
	patches = append(patches, jsonPatch{
		Op: "add",
		Path: "/metadata/annotations/" + strings.ReplaceAll(annotationKey, "/", "~1"),
		Value: "true",
	})

	return patches
}

func allow(msg string) *admissionv1.AdmissionResponse {
	return &admissionv1.AdmissionResponse{
		Allowed: true,
		Result:  &metav1.Status{Message: msg},
	}
}
