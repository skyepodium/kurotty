import Foundation

/// Which container in a pod a person actually meant.
///
/// **The painful part of `kubectl exec` is not typing it.** It is that a pod
/// has a dozen containers and only one of them is the application: the rest are
/// a service mesh proxy, a log shipper, a metrics agent, a secrets sidecar, and
/// an init container that exited an hour ago. A picker that lists all twelve
/// has moved the problem to a mouse rather than solved it.
///
/// So this ranks, and the caller shows the winner. Everything below is
/// information the cluster already published; none of it needs a person to
/// configure anything.
///
/// Pure: pods in, an order out. No `kubectl`, no network, no UI.
enum KubernetesContainerRanking {
    /// One container as the API describes it.
    struct Container: Equatable {
        let name: String
        let image: String
        /// False for a container that has finished or has not started — an init
        /// container that already exited cannot be entered at all.
        let isRunning: Bool
    }

    /// The pod, and the two things about it that decide the answer.
    struct Pod: Equatable {
        let containers: [Container]
        /// `kubectl.kubernetes.io/default-container`, which is Kubernetes' own
        /// answer to this exact question. Most charts set it; when one does,
        /// nothing else needs to be guessed.
        let defaultContainerAnnotation: String?
        /// The workload this pod belongs to — a Deployment or StatefulSet
        /// name, not the pod's. Pod names change on every deploy, so a memory
        /// keyed by pod is a memory that is always empty.
        let workload: String?
    }

    /// Names that mean "this is not the application".
    ///
    /// Matched against the container name *and* the image, because a chart is
    /// free to call the mesh proxy anything and the image is the honest half.
    /// Substrings rather than exact names for the same reason: `istio-proxy`,
    /// `istio-init` and `docker.io/istio/proxyv2` are all the same decision.
    private static let sidecarMARKERS = [
        "istio-proxy", "istio-init", "istio/proxyv2",
        "linkerd-proxy", "linkerd-init", "linkerd2-proxy",
        "envoy", "consul-connect",
        "vault-agent", "secrets-store",
        "cloudsql-proxy", "cloud-sql-proxy",
        "fluent-bit", "fluentd", "filebeat", "promtail", "vector",
        "otel-collector", "opentelemetry", "jaeger-agent",
        "datadog-agent", "newrelic", "dd-trace",
        "config-reloader", "kube-rbac-proxy", "oauth2-proxy",
    ]

    /// The order to offer containers in, best first.
    ///
    /// - Parameter lastChosen: what was picked last time for this pod's
    ///   workload, if anything. This outranks every heuristic: a person who has
    ///   already answered the question should not be asked it again.
    static func ranked(_ pod: Pod, lastChosen: String? = nil) -> [Container] {
        pod.containers.sorted { first, second in
            let firstScore = score(first, in: pod, lastChosen: lastChosen)
            let secondScore = score(second, in: pod, lastChosen: lastChosen)
            guard firstScore == secondScore else {
                return firstScore > secondScore
            }
            // A stable order, so the list does not shuffle between openings
            // even when nothing distinguishes two containers.
            return first.name < second.name
        }
    }

    /// The container to enter without asking, when there is one.
    ///
    /// Nil when the top two are equally good — that is the case where a person
    /// genuinely has to choose, and picking for them would be guessing with a
    /// shell.
    static func unambiguousChoice(_ pod: Pod, lastChosen: String? = nil) -> Container? {
        let ordered = ranked(pod, lastChosen: lastChosen)
        guard let best = ordered.first else {
            return nil
        }
        guard let runnerUp = ordered.dropFirst().first else {
            return best
        }
        guard score(best, in: pod, lastChosen: lastChosen)
            > score(runnerUp, in: pod, lastChosen: lastChosen)
        else {
            return nil
        }
        return best
    }

    /// Whether a container is a sidecar rather than the application.
    static func isSidecar(_ container: Container) -> Bool {
        let name = container.name.lowercased()
        let image = container.image.lowercased()
        return sidecarMARKERS.contains { name.contains($0) || image.contains($0) }
    }

    private enum Weight {
        /// Outranks everything: the person already answered this.
        static let lastChosen = 1_000
        /// Kubernetes' own answer, when the chart published one.
        static let annotated = 100
        /// A container that has exited cannot be entered, so this is a floor
        /// rather than a preference.
        static let running = 10
        /// Being the application rather than the infrastructure around it.
        static let notASidecar = 1
    }

    private static func score(_ container: Container, in pod: Pod, lastChosen: String?) -> Int {
        var score = 0
        if container.name == lastChosen {
            score += Weight.lastChosen
        }
        if container.name == pod.defaultContainerAnnotation {
            score += Weight.annotated
        }
        if container.isRunning {
            score += Weight.running
        }
        if !isSidecar(container) {
            score += Weight.notASidecar
        }
        return score
    }
}
