{{/*
Cluster name: explicit value wins, otherwise the ClusterDeployment/Release name.
*/}}
{{- define "capm3.clusterName" -}}
{{- default .Release.Name .Values.clusterName -}}
{{- end -}}

{{/*
Target namespace for all rendered objects.
*/}}
{{- define "capm3.namespace" -}}
{{- default .Release.Namespace .Values.namespace -}}
{{- end -}}

{{/*
Node OS image file name, e.g. CENTOS_10_NODE_IMAGE_K8S_v1.36.2-raw.img
*/}}
{{- define "capm3.imageFile" -}}
{{- printf "%s_NODE_IMAGE_K8S_%s-raw.img" .Values.imageOS .Values.k8sVersion -}}
{{- end -}}

{{/*
Full node OS image URL served from the httpd server.
*/}}
{{- define "capm3.imageURL" -}}
{{- printf "%s/%s" .Values.image.baseURL (include "capm3.imageFile" .) -}}
{{- end -}}

{{/*
Checksum URL for the node OS image.
*/}}
{{- define "capm3.imageChecksumURL" -}}
{{- printf "%s/%s.sha256sum" .Values.image.baseURL (include "capm3.imageFile" .) -}}
{{- end -}}
