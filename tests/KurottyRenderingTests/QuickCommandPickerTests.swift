import Foundation
import XCTest
@testable import KurottyApp

/// A quick command that produces choices, and the boundary that keeps a name
/// from a cluster out of the shell's grammar.
///
/// The listings here are the real shapes: `kubectl get pods -o json` and
/// `docker ps --format json` differ in almost every way except that both are
/// JSON somebody else wrote.
final class QuickCommandPickerTests: XCTestCase {
    // MARK: - The boundary

    /// A quick command reaches the shell as text on a pseudo-terminal — there
    /// is no argv to hand it. So a pod named `web; rm -rf /` is not a wrong
    /// command, it is two commands, and the second one runs.
    func testAValueCannotEscapeIntoTheShellsGrammar() {
        let hostile = [
            "web; rm -rf /",
            "web && curl evil.example",
            "web`whoami`",
            "web$(id)",
            "web|tee /tmp/x",
            "web\nrm -rf /",
            "web'; rm -rf /; '",
        ]

        for value in hostile {
            let filled = QuickCommandTemplate("kubectl exec -it {pod}").filled(with: ["pod": value])
            let command = try? XCTUnwrap(filled)

            XCTAssertEqual(
                command,
                "kubectl exec -it " + ShellArgumentQuoting.quoted(value),
                "\(value) was not confined to one word"
            )
        }
    }

    /// Single quotes make every byte literal in every POSIX shell, so the only
    /// character that has to leave the quoted run is the quote itself.
    func testAQuoteInsideAValueClosesAndReopensRatherThanEscaping() {
        XCTAssertEqual(ShellArgumentQuoting.quoted("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellArgumentQuoting.quoted("plain"), "'plain'")
        XCTAssertEqual(ShellArgumentQuoting.quoted(""), "''")
    }

    /// Always quoted, even when the value looks harmless: a rule with an
    /// exception is a rule somebody has to check, and "looks harmless" is what
    /// an attacker writes their input against.
    func testEvenAnInnocentValueIsQuoted() throws {
        let command = try XCTUnwrap(
            QuickCommandTemplate("docker exec -it {id} bash").filled(with: ["id": "abc123"])
        )

        XCTAssertEqual(command, "docker exec -it 'abc123' bash")
    }

    // MARK: - Templates

    func testATemplateSaysWhatItNeeds() {
        let template = QuickCommandTemplate("kubectl exec -it {pod} -c {container} -- {shell}")

        XCTAssertEqual(template.placeholders, ["pod", "container", "shell"])
    }

    /// `kubectl exec -it  -c web` is a command that runs and does something
    /// other than what was meant, which is worse than one that does not run.
    func testAMissingValueRefusesToProduceACommand() {
        let template = QuickCommandTemplate("kubectl exec -it {pod} -c {container}")

        XCTAssertNil(template.filled(with: ["pod": "web-1"]))
    }

    func testAMalformedTemplateRefusesRatherThanHalfRunning() {
        XCTAssertNil(QuickCommandTemplate("kubectl exec {pod").filled(with: ["pod": "web-1"]))
    }

    func testATemplateWithNoHolesIsItself() throws {
        XCTAssertEqual(try XCTUnwrap(QuickCommandTemplate("k9s").filled(with: [:])), "k9s")
    }

    // MARK: - Reading a listing

    private var kubectlOutput: Data {
        Data("""
        {"items": [
          {"metadata": {"name": "web-7d9f", "namespace": "prod"},
           "status": {"phase": "Running", "containerStatuses": [{"restartCount": 3}]}},
          {"metadata": {"name": "worker-22ab", "namespace": "prod"},
           "status": {"phase": "Running", "containerStatuses": [{"restartCount": 0}]}}
        ]}
        """.utf8)
    }

    func testAKubernetesListingBecomesChoices() {
        let source = QuickCommandPickSource(
            command: "kubectl get pods -o json",
            format: .jsonArray(itemsPath: "items"),
            fields: ["pod": "metadata.name", "namespace": "metadata.namespace"],
            label: "{pod}  ({namespace})"
        )

        let choices = source.choices(from: kubectlOutput)

        XCTAssertEqual(choices.count, 2)
        XCTAssertEqual(choices[0].label, "web-7d9f  (prod)")
        XCTAssertEqual(choices[0].values["pod"], "web-7d9f")
        XCTAssertEqual(choices[1].values["pod"], "worker-22ab")
    }

    /// `docker ps --format json` emits one object per line rather than an
    /// array, which is a different enough shape that guessing would be wrong.
    func testADockerListingBecomesChoices() {
        let output = Data("""
        {"ID": "a1b2", "Names": "api", "Image": "api:latest"}
        {"ID": "c3d4", "Names": "db", "Image": "postgres:16"}
        """.utf8)
        let source = QuickCommandPickSource(
            command: "docker ps --format json",
            format: .jsonLines,
            fields: ["id": "ID", "name": "Names"],
            label: "{name}"
        )

        let choices = source.choices(from: output)

        XCTAssertEqual(choices.map(\.label), ["api", "db"])
        XCTAssertEqual(choices[0].values["id"], "a1b2")
    }

    /// A picker whose rows are half-filled invites choosing one, and choosing
    /// one would produce a command with a missing argument.
    func testARowMissingAFieldIsDroppedRatherThanShownWithAHole() {
        let output = Data("""
        {"ID": "a1b2", "Names": "api"}
        {"ID": "c3d4"}
        """.utf8)
        let source = QuickCommandPickSource(
            command: "docker ps --format json",
            format: .jsonLines,
            fields: ["id": "ID", "name": "Names"],
            label: "{name}"
        )

        XCTAssertEqual(source.choices(from: output).count, 1)
    }

    /// A listing's useful columns include restart counts and ready flags, so a
    /// picker that could only show strings would be missing exactly those.
    func testANumberInAListingCanBeShown() {
        let source = QuickCommandPickSource(
            command: "kubectl get pods -o json",
            format: .jsonArray(itemsPath: "items"),
            fields: ["pod": "metadata.name", "phase": "status.phase"],
            label: "{pod} {phase}"
        )

        XCTAssertEqual(source.choices(from: kubectlOutput).first?.label, "web-7d9f Running")
    }

    func testGarbageOutputProducesNoChoicesRatherThanCrashing() {
        let source = QuickCommandPickSource(
            command: "kubectl get pods -o json",
            format: .jsonArray(itemsPath: "items"),
            fields: ["pod": "metadata.name"],
            label: "{pod}"
        )

        XCTAssertTrue(source.choices(from: Data("error: connection refused\n".utf8)).isEmpty)
        XCTAssertTrue(source.choices(from: Data()).isEmpty)
    }

    /// A label is text for a person and a command is text for a shell. Quoting
    /// the label would show `'web-7d9f'` in the list.
    func testALabelIsNotQuotedAndACommandAlwaysIs() throws {
        let source = QuickCommandPickSource(
            command: "kubectl get pods -o json",
            format: .jsonArray(itemsPath: "items"),
            fields: ["pod": "metadata.name"],
            label: "{pod}"
        )
        let choice = try XCTUnwrap(source.choices(from: kubectlOutput).first)

        XCTAssertEqual(choice.label, "web-7d9f")
        XCTAssertEqual(
            try XCTUnwrap(QuickCommandTemplate("kubectl exec {pod}").filled(with: choice.values)),
            "kubectl exec 'web-7d9f'"
        )
    }
}

/// Which container in a pod a person actually meant.
///
/// The pods here are the shapes that make `kubectl exec` annoying: a mesh
/// proxy beside the app, an init container that already exited, and a chart
/// that published the answer.
final class KubernetesContainerRankingTests: XCTestCase {
    private typealias Container = KubernetesContainerRanking.Container
    private typealias Pod = KubernetesContainerRanking.Pod

    private func pod(
        _ containers: [Container],
        annotation: String? = nil,
        workload: String? = "web"
    ) -> Pod {
        Pod(containers: containers, defaultContainerAnnotation: annotation, workload: workload)
    }

    private func container(_ name: String, image: String = "app:1", running: Bool = true) -> Container {
        Container(name: name, image: image, isRunning: running)
    }

    /// The shape that makes this feature worth building: one application and
    /// five pieces of infrastructure.
    func testTheApplicationOutranksItsSidecars() {
        let ordered = KubernetesContainerRanking.ranked(pod([
            container("istio-proxy", image: "docker.io/istio/proxyv2:1.20"),
            container("vault-agent", image: "hashicorp/vault:1.15"),
            container("api", image: "registry/api:2026.8"),
            container("fluent-bit", image: "fluent/fluent-bit:2.2"),
            container("otel-collector", image: "otel/opentelemetry-collector:0.9"),
        ]))

        XCTAssertEqual(ordered.first?.name, "api")
    }

    /// Kubernetes' own answer to this question. When a chart published one,
    /// nothing else needs to be guessed.
    func testTheChartsOwnAnswerWins() {
        let ordered = KubernetesContainerRanking.ranked(
            pod([container("api"), container("worker")], annotation: "worker")
        )

        XCTAssertEqual(ordered.first?.name, "worker")
    }

    /// A person who has already answered should not be asked again — and the
    /// memory is keyed by workload, because pod names change on every deploy.
    func testWhatWasChosenLastTimeOutranksEveryHeuristic() {
        let subject = pod([container("api"), container("worker")], annotation: "api")
        let ordered = KubernetesContainerRanking.ranked(subject, lastChosen: "worker")

        XCTAssertEqual(ordered.first?.name, "worker")
    }

    /// An init container that already exited cannot be entered at all, so this
    /// is a floor rather than a preference.
    func testAContainerThatIsNotRunningSinksBelowOneThatIs() {
        let ordered = KubernetesContainerRanking.ranked(pod([
            container("migrate", running: false),
            container("istio-proxy", image: "istio/proxyv2:1.20", running: true),
        ]))

        XCTAssertEqual(ordered.first?.name, "istio-proxy", "a running sidecar beats a dead app container")
    }

    /// A chart is free to call the mesh proxy anything, and the image is the
    /// honest half.
    func testASidecarIsRecognisedByItsImageWhenItsNameHides() {
        XCTAssertTrue(KubernetesContainerRanking.isSidecar(
            container("sidecar", image: "docker.io/istio/proxyv2:1.20")
        ))
        XCTAssertFalse(KubernetesContainerRanking.isSidecar(
            container("api", image: "registry.example/api:2026.8")
        ))
    }

    func testASinglePodContainerNeedsNoChoiceAtAll() {
        let choice = KubernetesContainerRanking.unambiguousChoice(pod([container("api")]))

        XCTAssertEqual(choice?.name, "api")
    }

    func testTheCommonCaseIsAnsweredWithoutAsking() {
        let choice = KubernetesContainerRanking.unambiguousChoice(pod([
            container("istio-proxy", image: "istio/proxyv2:1.20"),
            container("api"),
        ]))

        XCTAssertEqual(choice?.name, "api")
    }

    /// Two application containers in one pod is the case where a person
    /// genuinely has to choose, and picking for them would be guessing with a
    /// shell.
    func testTwoEquallyGoodContainersAreLeftToThePerson() {
        XCTAssertNil(KubernetesContainerRanking.unambiguousChoice(
            pod([container("api"), container("worker")])
        ))
    }

    /// The list must not shuffle between openings when nothing distinguishes
    /// two containers.
    func testTheOrderIsStable() {
        let subject = pod([container("zeta"), container("alpha"), container("mu")])

        XCTAssertEqual(
            KubernetesContainerRanking.ranked(subject).map(\.name),
            KubernetesContainerRanking.ranked(subject).map(\.name)
        )
        XCTAssertEqual(KubernetesContainerRanking.ranked(subject).first?.name, "alpha")
    }
}
