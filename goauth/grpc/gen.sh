#!/usr/bin/env bash

GRPC_GW_PATH=`go list -f '{{ .Dir }}' github.com/grpc-ecosystem/grpc-gateway/protoc-gen-grpc-gateway`
GRPC_GW_PATH="${GRPC_GW_PATH}/../third_party/googleapis"

LS_PATH=`go list -f '{{ .Dir }}' github.com/iegomez/mosquitto-go-auth/grpc`
LS_PATH="${LS_PATH}/../.."

# Ensure the protoc plugin tools are available in PATH.
echo "Installing protoc-gen-go and protoc-gen-go-grpc (may already be cached in module bin path)..."
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

# generate the gRPC code with the new protoc-gen-go and protoc-gen-go-grpc plugins
protoc -I. -I${LS_PATH} -I${GRPC_GW_PATH} \
    --go_out=paths=source_relative:. \
    --go-grpc_out=paths=source_relative:. \
    auth.proto