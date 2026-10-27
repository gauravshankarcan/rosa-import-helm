{{/*
Expand chart name.
*/}}
{{- define "rosa-acm-import.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Managed cluster / namespace name.
*/}}
{{- define "rosa-acm-import.clusterName" -}}
{{- $n := required "clusterName is required (e.g. terranova-rosa-gs)" .Values.clusterName -}}
{{- $n | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Namespace for import artifacts (must match ManagedCluster name for ACM auto-import).
*/}}
{{- define "rosa-acm-import.namespace" -}}
{{- if and .Values.namespace .Values.namespace.name -}}
{{- .Values.namespace.name -}}
{{- else -}}
{{- include "rosa-acm-import.clusterName" . -}}
{{- end -}}
{{- end -}}

{{/*
Common labels for ManagedCluster.
*/}}
{{- define "rosa-acm-import.managedClusterLabels" -}}
name: {{ include "rosa-acm-import.clusterName" . | quote }}
cloud: {{ .Values.labels.cloud | quote }}
vendor: {{ .Values.labels.vendor | quote }}
cluster.open-cluster-management.io/clusterset: {{ .Values.clusterSet | quote }}
{{- range $k, $v := .Values.labels }}
{{- if and (ne $k "cloud") (ne $k "vendor") }}
{{ $k }}: {{ $v | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Validate that either token+server or kubeconfig is provided.
*/}}
{{- define "rosa-acm-import.validateImport" -}}
{{- $hasToken := and .Values.import.token .Values.import.server -}}
{{- $hasKube := .Values.import.kubeconfig -}}
{{- if and (not $hasToken) (not $hasKube) -}}
{{- fail "import.token+import.server OR import.kubeconfig is required" -}}
{{- end -}}
{{- if and $hasToken $hasKube -}}
{{- fail "provide either import.token+import.server OR import.kubeconfig, not both" -}}
{{- end -}}
{{- end -}}
