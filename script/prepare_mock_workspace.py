#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unicodedata
import uuid

SCENARIO = "linked-worktree-selected"
SESSION_FILE = "mock-session.json"
REPOSITORIES = ["catalog-service", "inventory-service", "ios-client", "macos-client", "order-service", "payment-service", "storefront-web"]
GROUPS = {
    "feature-store-pickup": ["inventory-service", "ios-client", "macos-client", "order-service", "storefront-web"],
    "fix-overselling": ["inventory-service", "order-service", "payment-service"],
}


def main():
    parser = argparse.ArgumentParser(description="Prepare an isolated local Git workspace before launching the Debug app.")
    commands = parser.add_subparsers(dest="mode", required=True)
    commands.add_parser("allocate")
    prepare = commands.add_parser("prepare")
    prepare.add_argument("--directory", required=True)
    prepare.add_argument("--build", nargs=argparse.REMAINDER, default=[])
    cleanup = commands.add_parser("cleanup")
    cleanup.add_argument("--directory", required=True)
    arguments = parser.parse_args()
    for number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(number, interrupt)
    try:
        if arguments.mode == "allocate":
            print(allocate())
        elif arguments.mode == "cleanup":
            remove_session(Path(arguments.directory))
        else:
            prepare_session(Path(arguments.directory), arguments.build)
        return 0
    except Cancelled as error:
        print("Mock preparation interrupted.", file=sys.stderr)
        return 128 + error.number
    except (OSError, ValueError, RuntimeError) as error:
        print(f"Mock preparation failed: {error}", file=sys.stderr)
        return 1


def prepare_session(directory, build_command):
    directory = Path(app_path(directory))
    if not directory.exists():
        create_session(directory)
    session = read_session(directory)
    if session["ready"] or set(directory.iterdir()) != {directory / SESSION_FILE}:
        raise ValueError("Preparation requires a newly allocated, empty mock session.")
    jobs = Jobs()
    try:
        if build_command:
            jobs.build = jobs.start(build_command)
        print(f"Preparing mock workspace: {directory / 'example-workspace'}", flush=True)
        generate(directory, jobs)
        if jobs.build is not None and jobs.build.wait() != 0:
            raise RuntimeError("Debug build failed.")
        session["ready"] = True
        write_json(directory / SESSION_FILE, session)
        print(f"Mock workspace ready: {session['workspace']}", flush=True)
    except BaseException:
        for number in (signal.SIGINT, signal.SIGTERM):
            signal.signal(number, signal.SIG_IGN)
        jobs.stop()
        remove_session(directory)
        raise


def generate(directory, jobs):
    root = directory / "example-workspace"
    config = directory / "gitconfig"
    root.mkdir()
    (directory / "home").mkdir()
    templates = directory / "templates"
    write(templates / "config", f'[include]\n    path = "{config}"\n')
    write(config, f"""[url "{(directory / 'remotes').as_uri()}/"]
    insteadOf = https://example.invalid/
[protocol]
    allow = never
[protocol "file"]
    allow = always
[init]
    defaultBranch = main
    templateDir = "{templates}"
[core]
    hooksPath = /dev/null
    excludesFile = /dev/null
    fsmonitor = false
[commit]
    gpgSign = false
[status]
    renames = true
""")
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": str(config), "GIT_ALLOW_PROTOCOL": "file", "GIT_TERMINAL_PROMPT": "0",
                        "GIT_AUTHOR_NAME": "Jamie Lee", "GIT_AUTHOR_EMAIL": "jamie@example.invalid",
                        "GIT_COMMITTER_NAME": "Jamie Lee", "GIT_COMMITTER_EMAIL": "jamie@example.invalid",
                        "GIT_AUTHOR_DATE": "2026-08-29T00:00:00Z", "GIT_COMMITTER_DATE": "2026-08-29T00:00:00Z"})

    def git(path, *arguments, date=None):
        values = environment if date is None else dict(environment, GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
        jobs.run(["/usr/bin/git", *arguments], cwd=path, environment=values)

    def commit(path, subject, date=None):
        git(path, "add", "--all")
        git(path, "commit", "--quiet", "-m", subject, date=date)

    git(root, "init", "--quiet", "-b", "main")
    git(root, "config", "--local", "include.path", str(config))
    write(root / ".gitignore", "/repositories/\n/worktrees/\n" + "".join(f"/{name}/\n" for name in REPOSITORIES))
    skill = Path(__file__).resolve().parent.parent / "ModuDesktop/Resources/modu-workflow/SKILL.md"
    write(root / ".agents/skills/modu-workflow/SKILL.md", skill.read_text())
    commit(root, "chore: initialize Modu workspace")
    write(root / "README.md", "# Modu sample workspace\n\nThis Debug workspace is temporary. It is deleted when Modu quits.\n")
    commit(root, "docs: describe sample workspace")
    for name in REPOSITORIES:
        source = directory / "sources" / name
        remote = directory / "remotes" / f"{name}.git"
        source.mkdir(parents=True)
        remote.parent.mkdir(exist_ok=True)
        git(source, "init", "--quiet", "-b", "main")
        write(source / "README.md", f"# {name}\n\nSample files for Modu's temporary Debug workspace.\n")
        for path, contents in baseline_files(name).items():
            write(source / path, contents)
        commit(source, f"chore: initialize {name}")
        git(directory, "clone", "--quiet", "--bare", "--", str(source), str(remote))
        repository = root / "repositories" / name
        repository.parent.mkdir(exist_ok=True)
        git(root, "clone", "--quiet", "--no-recurse-submodules", "--", f"https://example.invalid/{name}.git", str(repository))
        git(repository, "config", "--local", "include.path", str(config))
    for group, members in GROUPS.items():
        destination = root / "worktrees" / group
        destination.parent.mkdir(exist_ok=True)
        git(root, "worktree", "add", "--quiet", "-b", group, str(destination), "HEAD")
        for name in members:
            git(root / "repositories" / name, "worktree", "add", "--quiet", "-b", group, str(destination / name), "origin/main")
    order_changes(root / "worktrees/feature-store-pickup/order-service", git, commit)
    write(root / "worktrees/feature-store-pickup/storefront-web/src/pickup.ts",
          "export function pickupMessage(location: string): string {\n  return `Ready for pickup at ${location}`;\n}\n")
    record = {"version": 1, "root": str(root), "repositories": [{"url": f"https://example.invalid/{name}.git"} for name in REPOSITORIES],
              "groups": {name: {"created-at": "2026-08-30T00:00:00Z", "repositories": members} for name, members in GROUPS.items()}}
    identity = unicodedata.normalize("NFC", str(root))
    alternate = root.with_name(root.name.swapcase())
    if alternate.exists() and os.path.samefile(root, alternate):
        identity = identity.lower()
    key = hashlib.sha256(identity.encode()).hexdigest()
    write_json(directory / "support/workspaces" / f"{key}.json", record)


def order_changes(path, git, commit):
    write(path / "internal/order/domain/fulfillment.go", "package order\n\ntype FulfillmentType string\n\nconst (\n    Delivery FulfillmentType = \"delivery\"\n    StorePickup FulfillmentType = \"store-pickup\"\n)\n")
    commit(path, "feat(order): add pickup fulfillment type", "2026-08-30T03:07:00Z")
    write(path / "internal/order/application/pickup_eligibility.go", "package application\n\nfunc PickupEligible(locationID string) bool {\n    return locationID != \"\"\n}\n")
    commit(path, "feat(order): validate pickup eligibility", "2026-08-30T06:42:00Z")
    write(path / "internal/order/domain/fulfillment_test.go", "package order\n\nimport \"testing\"\n\nfunc TestStorePickup(t *testing.T) {\n    if StorePickup == Delivery {\n        t.Fatal(\"pickup and delivery must be different\")\n    }\n}\n")
    commit(path, "test(order): cover pickup fulfillment rules", "2026-08-30T08:18:00Z")
    write(path / "internal/order/application/create_pickup_order.go", "package application\n\nimport \"example.invalid/order-service/internal/order/domain\"\n\nfunc CreatePickupOrder(id, locationID string) order.Order {\n    return order.Order{ID: id, PickupLocationID: locationID}\n}\n")
    write(path / "internal/order/domain/pickup.go", "package order\n\ntype Pickup struct {\n    LocationID string\n}\n")
    git(path, "add", "--", "internal/order/application/create_pickup_order.go", "internal/order/domain/pickup.go")
    write(path / "internal/order/domain/order.go", "package order\n\ntype Order struct {\n    ID string\n    PickupLocationID string\n}\n")
    (path / "internal/order/infrastructure/persistence/legacy_pickup_repository.go").unlink()
    git(path, "mv", "--", "internal/order/interfaces/http/order_handler.go", "internal/order/interfaces/http/pickup_handler.go")


def baseline_files(name):
    if name == "order-service":
        return {"go.mod": "module example.invalid/order-service\n\ngo 1.22\n",
                "internal/order/domain/order.go": "package order\n\ntype Order struct {\n    ID string\n}\n",
                "internal/order/infrastructure/persistence/legacy_pickup_repository.go": "package persistence\n\nfunc LegacyPickupEnabled() bool {\n    return false\n}\n",
                "internal/order/interfaces/http/order_handler.go": "package http\n\nfunc HandlerName() string {\n    return \"order\"\n}\n"}
    if name == "storefront-web":
        return {"package.json": '{"name":"storefront-web","private":true}\n',
                "src/pickup.ts": "export function pickupMessage(location: string): string {\n  return `Pickup location: ${location}`;\n}\n"}
    if name in ("ios-client", "macos-client"):
        return {"Sources/Client.swift": "import Foundation\n\nstruct PickupLocation: Identifiable {\n    let id: String\n    let name: String\n}\n"}
    return {"go.mod": f"module example.invalid/{name}\n\ngo 1.22\n", "internal/service/service.go": f'package service\n\nconst Name = "{name}"\n'}


def allocate():
    directory = Path(app_path(Path(tempfile.gettempdir()))) / f"modu-mock-{uuid.uuid4()}"
    create_session(directory)
    return directory


def create_session(directory):
    identifier = checked_identifier(directory)
    directory.mkdir(mode=0o700)
    try:
        write_json(directory / SESSION_FILE, {"version": 1, "identifier": identifier, "scenario": SCENARIO,
                                            "workspace": str(directory / "example-workspace"), "ready": False})
    except BaseException:
        shutil.rmtree(directory)
        raise


def read_session(directory):
    identifier = checked_identifier(directory)
    path = directory / SESSION_FILE
    if path.is_symlink():
        raise ValueError("Mock session marker must be a regular file.")
    session = json.loads(path.read_text())
    if session.get("version") != 1 or session.get("identifier") != identifier or session.get("scenario") != SCENARIO or not isinstance(session.get("workspace"), str) or app_path(Path(session["workspace"])) != app_path(directory / "example-workspace") or not isinstance(session.get("ready"), bool):
        raise ValueError("Invalid mock session marker.")
    return session


def checked_identifier(directory):
    if directory.is_symlink() or not directory.name.startswith("modu-mock-"):
        raise ValueError("Expected an owned temporary mock directory.")
    resolved = directory.resolve()
    bases = [Path(tempfile.gettempdir()).resolve(), Path("/tmp").resolve()]
    if not any(base in resolved.parents for base in bases):
        raise ValueError("Mock data must be inside a temporary directory.")
    identifier = directory.name.removeprefix("modu-mock-")
    if str(uuid.UUID(identifier)) != identifier:
        raise ValueError("Invalid mock directory identifier.")
    return identifier


def app_path(path):
    resolved = str(path.resolve())
    # Foundation canonicalizes these macOS aliases without the /private prefix.
    if sys.platform == "darwin" and (resolved == "/private/tmp" or resolved.startswith("/private/tmp/") or resolved.startswith("/private/var/")):
        return resolved.removeprefix("/private")
    return resolved


def remove_session(directory):
    if directory.exists():
        read_session(directory)
        shutil.rmtree(directory)


def write(path, contents):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents)


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    write(temporary, json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(path)


def interrupt(number, _):
    raise Cancelled(number)


class Cancelled(Exception):
    def __init__(self, number):
        self.number = number


class Jobs:
    def __init__(self):
        self.build = None
        self.processes = []

    def start(self, command, **options):
        process = subprocess.Popen(command, start_new_session=True, **options)
        self.processes.append(process)
        return process

    def run(self, command, cwd, environment):
        process = self.start(command, cwd=cwd, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        while True:
            if self.build is not None and self.build.poll() not in (None, 0):
                raise RuntimeError("Debug build failed.")
            try:
                _, error = process.communicate(timeout=0.05)
                break
            except subprocess.TimeoutExpired:
                pass
        if process.returncode != 0:
            raise RuntimeError(error.strip() or "Git fixture command failed.")
        self.processes.remove(process)

    def stop(self):
        for process in self.processes:
            self.signal_group(process, signal.SIGTERM)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            alive = []
            for process in self.processes:
                process.poll()
                if self.group_exists(process):
                    alive.append(process)
            if not alive:
                break
            time.sleep(0.02)
        for process in self.processes:
            self.signal_group(process, signal.SIGKILL)
            process.wait()

    def signal_group(self, process, number):
        try:
            os.killpg(process.pid, number)
        except ProcessLookupError:
            pass
        except PermissionError:
            if self.group_exists(process):
                raise

    def group_exists(self, process):
        try:
            os.killpg(process.pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            # macOS can deny signal probes after the last owned group member exits.
            groups = subprocess.check_output(["/bin/ps", "-axo", "pgid="], text=True).split()
            return str(process.pid) in groups


if __name__ == "__main__":
    sys.exit(main())
