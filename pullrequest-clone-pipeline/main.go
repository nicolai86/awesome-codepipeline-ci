package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"os"

	"github.com/aws/aws-sdk-go/aws/awserr"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/codepipeline"
	"github.com/eawsy/aws-lambda-go-core/service/lambda/runtime"
	"github.com/google/go-github/github"
)

var githubOAuthToken = ""
var codepipelineTemplate = ""

func pipelineExists(target string) bool {
	sess := session.Must(session.NewSession())

	svc := codepipeline.New(sess)

	resp, _ := svc.GetPipeline(&codepipeline.GetPipelineInput{
		Name: &target,
	})
	return resp.Pipeline != nil
}

func clonePipeline(source, target, branch string) error {
	sess := session.Must(session.NewSession())

	svc := codepipeline.New(sess)

	resp, err := svc.GetPipeline(&codepipeline.GetPipelineInput{
		Name: &source,
	})
	if err != nil {
		return err
	}

	pipeline := &codepipeline.PipelineDeclaration{
		Name:          &target,
		RoleArn:       resp.Pipeline.RoleArn,
		ArtifactStore: resp.Pipeline.ArtifactStore,
		Stages:        resp.Pipeline.Stages,
	}
	oauth_token := os.Getenv("GITHUB_OAUTH_TOKEN")
	if oauth_token == "" {
		oauth_token = githubOAuthToken
	}
	pipeline.Stages[0].Actions[0].Configuration["OAuthToken"] = &oauth_token
	pipeline.Stages[0].Actions[0].Configuration["Branch"] = &branch

	_, err = svc.CreatePipeline(&codepipeline.CreatePipelineInput{
		Pipeline: pipeline,
	})
	return err
}

func destroyPipeline(target string) error {
	sess := session.Must(session.NewSession())

	svc := codepipeline.New(sess)

	_, err := svc.DeletePipeline(&codepipeline.DeletePipelineInput{
		Name: &target,
	})
	return err
}

type evtStructure struct {
	Header map[string]string `json:"header"`
	Body   json.RawMessage   `json:"body"`
}

type response struct {
	Header     map[string]string `json:"header"`
	Error      string            `json:",omitempty"`
	Status     string            `json:"status"`
	HTTPStatus int               `json:"httpStatus"`
	RequestID  string            `json:"requestId"`
}

func Handle(evt json.RawMessage, ctx *runtime.Context) (string, error) {
	var payload evtStructure
	json.Unmarshal(evt, &payload)

	var rsp = response{
		Header:    make(map[string]string),
		RequestID: ctx.AWSRequestID,
	}

	if payload.Header["X-GitHub-Event"] == "pull_request" {
		prEvt := new(github.PullRequestEvent)
		json.Unmarshal(payload.Body, prEvt)
		prName := fmt.Sprintf("pr-%d", *prEvt.PullRequest.Number)
		if *prEvt.PullRequest.State == "open" {
			if !pipelineExists(prName) {
				err := clonePipeline(codepipelineTemplate, prName, *prEvt.PullRequest.Head.Ref)
				if v, ok := err.(awserr.Error); ok {
					log.Printf("failed: %#v %#v\n", v.Message(), v.OrigErr())
				}
			}
		} else if *prEvt.PullRequest.State == "closed" {
			if pipelineExists(prName) {
				err := destroyPipeline(prName)
			}
		}
		rsp.Header["X-GitHub-Delivery"] = payload.Header["X-GitHub-Delivery"]
		rsp.Status = "ok"
		rsp.HTTPStatus = 200
	} else {
		rsp.Error = fmt.Sprintf("unhandled %s", payload.Header["X-GitHub-Event"])
		rsp.Status = "error"
		rsp.HTTPStatus = 200
	}

	var b = bytes.Buffer{}
	json.NewEncoder(&b).Encode(rsp)
	return b.String(), nil
}
