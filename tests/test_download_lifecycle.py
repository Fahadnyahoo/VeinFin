#!/usr/bin/env python3
"""Deterministic offline tests for Download lifecycle setup cleanup eligibility."""

import importlib.util
import ipaddress
import json
import os
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("download_lifecycle", ROOT / "scripts/deploy/download_lifecycle.py")
DOWNLOAD_LIFECYCLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DOWNLOAD_LIFECYCLE)


class SshContextTests(unittest.TestCase):
    def setUp(self):
        self.client = str(ipaddress.ip_address(1))
        self.server = str(ipaddress.ip_address(2))
        self.connection = f"{self.client} 32123 {self.server} 22"
        self.socket = f"ESTAB 0 0 {self.server}:22 {self.client}:32123\n"

    def test_exact_established_session_matches(self):
        self.assertTrue(DOWNLOAD_LIFECYCLE.ssh_session_matches(self.connection, self.socket))

    def test_absent_malformed_and_injected_context_is_rejected(self):
        values = ("", "missing fields", self.connection + " extra",
                  self.connection + "\ntext", f"{self.client};command 1 {self.server} 22",
                  f"{self.client} 0 {self.server} 22")
        for value in values:
            with self.subTest(value=repr(value)), self.assertRaises(RuntimeError):
                DOWNLOAD_LIFECYCLE.parse_ssh_connection(value)

    def test_inconsistent_or_duplicate_socket_does_not_match(self):
        wrong = f"ESTAB 0 0 {self.server}:22 {self.client}:32124\n"
        self.assertFalse(DOWNLOAD_LIFECYCLE.ssh_session_matches(self.connection, wrong))
        self.assertFalse(DOWNLOAD_LIFECYCLE.ssh_session_matches(self.connection, self.socket + self.socket))


class CleanupDecisionTests(unittest.TestCase):
    def setUp(self):
        self.root = "/data/torrents/.veinfin-download_lifecycle-validation"
        self.torrent = {"state": "stoppedUP", "progress": 1.0, "ratio": 1.0,
                        "seeding_time": 0, "category": "download_lifecycle-validation",
                        "save_path": self.root + "/fixture/source",
                        "content_path": self.root + "/fixture/source/file.bin"}
        self.file = {"source_exists": True, "import_exists": True, "same_device": True,
                     "same_inode": True, "same_bytes": True, "link_count": 2}
        self.evidence = {"status": "successful", "expected_files": 1,
                         "partial": False, "failed": False, "files": [self.file]}

    def decision(self, torrent=None, evidence=None):
        return DOWNLOAD_LIFECYCLE.cleanup_decision(torrent if torrent is not None else self.torrent,
            evidence if evidence is not None else self.evidence, validation_root=self.root)

    def test_below_both_thresholds_is_retained(self):
        value = dict(self.torrent, ratio=0.99, seeding_time=1439 * 60)
        self.assertEqual(self.decision(value), (False, "share-limit-not-reached"))

    def test_ratio_or_time_is_sufficient_after_import(self):
        self.assertEqual(self.decision()[0], True)
        value = dict(self.torrent, ratio=0.0, seeding_time=1440 * 60)
        self.assertEqual(self.decision(value)[0], True)

    def test_threshold_without_import_is_retained(self):
        self.assertEqual(self.decision(evidence={}), (False, "import-evidence-missing"))

    def test_failed_partial_and_short_imports_are_retained(self):
        for update, reason in (({"failed": True}, "import-not-complete"),
                               ({"partial": True}, "import-not-complete"),
                               ({"expected_files": 2}, "partial-import")):
            evidence = dict(self.evidence, **update)
            self.assertEqual(self.decision(evidence=evidence), (False, reason))

    def test_active_checking_moving_queued_and_downloading_are_retained(self):
        for state in ("downloading", "checkingUP", "moving", "queuedUP", "uploading"):
            self.assertEqual(self.decision(dict(self.torrent, state=state))[0], False)

    def test_unknown_category_and_outside_path_are_retained(self):
        self.assertEqual(self.decision(dict(self.torrent, category="other")), (False, "unknown-category"))
        self.assertEqual(self.decision(dict(self.torrent, save_path="/data/torrents/anime")),
                         (False, "path-outside-validation-root"))
        traversal = self.root + "/fixture/../../../library/anime"
        self.assertEqual(self.decision(dict(self.torrent, content_path=traversal)),
                         (False, "path-outside-validation-root"))

    def test_symlink_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory); root = base / "validation"; root.mkdir()
            outside = base / "outside"; outside.mkdir(); (root / "escape").symlink_to(outside, target_is_directory=True)
            torrent = dict(self.torrent, save_path=str(root), content_path=str(root / "escape/file"))
            self.assertEqual(DOWNLOAD_LIFECYCLE.cleanup_decision(torrent, self.evidence, validation_root=str(root)),
                             (False, "path-outside-validation-root"))

    def test_missing_hardlink_and_copy_are_retained(self):
        for key in ("source_exists", "import_exists", "same_device", "same_inode", "same_bytes"):
            item = dict(self.file, **{key: False}); evidence = dict(self.evidence, files=[item])
            self.assertEqual(self.decision(evidence=evidence), (False, "hardlink-proof-failed"))
        item = dict(self.file, link_count=1)
        self.assertEqual(self.decision(evidence=dict(self.evidence, files=[item])),
                         (False, "hardlink-proof-failed"))

    def test_multiple_files_require_complete_hardlink_evidence(self):
        evidence = dict(self.evidence, expected_files=2, files=[self.file, dict(self.file, same_inode=False)])
        self.assertEqual(self.decision(evidence=evidence), (False, "hardlink-proof-failed"))

    def test_correct_complete_hardlink_is_eligible_and_repeatable(self):
        first = self.decision(); second = self.decision()
        self.assertEqual(first, (True, "eligible")); self.assertEqual(second, first)

    def test_empty_and_malformed_inputs_fail_closed(self):
        for torrent, evidence in ((None, {}), ({}, {}), (self.torrent, None),
                                  (dict(self.torrent, ratio="invalid"), self.evidence)):
            self.assertFalse(DOWNLOAD_LIFECYCLE.cleanup_decision(torrent, evidence)[0])


class ArtifactTests(unittest.TestCase):
    def test_private_torrent_has_no_tracker_metadata(self):
        metadata, info_hash, info_bytes = DOWNLOAD_LIFECYCLE.torrent_bytes("fixture.bin", b"fixture")
        self.assertIn(b"7:privatei1e", metadata)
        for forbidden in (b"announce", b"url-list", b"httpseeds", b"source", b"http://", b"https://", b"udp://"):
            self.assertNotIn(forbidden, metadata)
        self.assertEqual(len(info_hash), 40)
        self.assertEqual(info_hash, DOWNLOAD_LIFECYCLE.hashlib.sha1(info_bytes).hexdigest())
        self.assertIn(b"4:info" + info_bytes, metadata)

    def test_atomic_output_is_mode_0600(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "state.json"
            DOWNLOAD_LIFECYCLE.atomic_json(path, {"safe": True}, os.getuid(), os.getgid())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(path.read_text()), {"safe": True})

    def test_tracked_policy_is_exact(self):
        value = DOWNLOAD_LIFECYCLE.policy(ROOT / "config/download-lifecycle-policy.json")
        self.assertEqual((value["ratio_limit"], value["seeding_time_minutes"],
                          value["share_limits_mode"], value["share_limit_action"]),
                         (1.0, 1440, "MatchAny", "Stop"))


class FakeQbit:
    def __init__(self, inventories=None, response=b"Ok.", files=None, properties=None,
                 trackers=None, webseeds=None, peers=None):
        self.inventories=list(inventories or [[]]); self.response=response; self.files=files or []
        self.properties=properties or {"isPrivate":True}; self.trackers=trackers or []
        self.webseeds=webseeds or []; self.peers=peers or {"peers":{}}; self.posts=[]; self.multipart_calls=0
    def multipart(self,*args): self.multipart_calls+=1; return self.response
    def get(self,path):
        if path == "torrents/info" or path.startswith("torrents/info?hashes="):
            if len(self.inventories)>1: return self.inventories.pop(0)
            return self.inventories[0]
        if path.startswith("torrents/files?"): return self.files
        if path.startswith("torrents/properties?"): return self.properties
        if path.startswith("torrents/trackers?"): return self.trackers
        if path.startswith("torrents/webseeds?"): return self.webseeds
        if path.startswith("sync/torrentPeers?"): return self.peers
        raise AssertionError(path)
    def post(self,path,body): self.posts.append((path,body))


class AdmissionAndPathTests(unittest.TestCase):
    def setUp(self):
        self.payload=b"fixture"; self.meta,self.hash,self.info=DOWNLOAD_LIFECYCLE.torrent_bytes("fixture.bin",self.payload)
        self.expected={"hash":self.hash,"name":"fixture.bin","category":"download_lifecycle-validation",
                       "tags":"download_lifecycle-validation","size":len(self.payload),"state":"stoppedDL",
                       "content_path":"/data/torrents/incomplete/.veinfin-download_lifecycle-validation/case/fixture.bin",
                       "save_path":"/data/torrents/.veinfin-download_lifecycle-validation/case/source"}
        self.fields={"category":"download_lifecycle-validation","tags":"download_lifecycle-validation","stopped":"true"}

    def admit(self,q,attempts=2):
        return DOWNLOAD_LIFECYCLE.admit_torrent(q,self.meta,self.hash,"fixture.bin",len(self.payload),self.fields,
                                     attempts=attempts,sleep_fn=lambda _:None)

    def test_ok_body_without_admission_fails(self):
        with self.assertRaises(RuntimeError): self.admit(FakeQbit([[],[],[]],b"Ok."))

    def test_empty_body_with_exact_hash_admission_succeeds(self):
        q=FakeQbit([[],[self.expected]],b"")
        self.assertEqual(self.admit(q)["hash"],self.hash)

    def test_unexpected_body_with_exact_hash_admission_succeeds(self):
        q=FakeQbit([[],[self.expected]],b"unexpected transport text")
        self.assertEqual(self.admit(q)["name"],"fixture.bin")

    def test_duplicate_or_conflicting_identity_fails(self):
        for inventory in ([self.expected,self.expected], [dict(self.expected,hash="0"*40)]):
            with self.assertRaises(RuntimeError): self.admit(FakeQbit([[],inventory]))

    def test_info_hash_uses_exact_raw_info_dictionary(self):
        self.assertEqual(self.hash,DOWNLOAD_LIFECYCLE.hashlib.sha1(self.info).hexdigest())
        self.assertEqual(self.meta[self.meta.index(b"4:info")+6:-1],self.info)

    def test_container_to_host_incomplete_and_completed_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            media=pathlib.Path(directory); (media/"torrents/incomplete").mkdir(parents=True)
            incomplete=DOWNLOAD_LIFECYCLE.container_to_host(self.expected["content_path"],media)
            completed=DOWNLOAD_LIFECYCLE.container_to_host("/data/torrents/.veinfin-download_lifecycle-validation/case/source/fixture.bin",media)
            resolved=media.resolve()
            self.assertEqual(incomplete,resolved/"torrents/incomplete/.veinfin-download_lifecycle-validation/case/fixture.bin")
            self.assertEqual(completed,resolved/"torrents/.veinfin-download_lifecycle-validation/case/source/fixture.bin")

    def test_traversal_symlink_and_wrong_root_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            media=pathlib.Path(directory); (media/"torrents/incomplete").mkdir(parents=True)
            outside=media/"outside"; outside.mkdir()
            (media/"torrents/incomplete/.veinfin-download_lifecycle-validation").symlink_to(outside)
            for value in ("/data/torrents/incomplete/.veinfin-download_lifecycle-validation/../anime/file",
                          "/data/torrents/anime/file",
                          "/data/library/anime/file",
                          "/data/torrents/incomplete/.veinfin-download_lifecycle-validation/file"):
                with self.assertRaises(RuntimeError): DOWNLOAD_LIFECYCLE.container_to_host(value,media)

    def test_completed_state_variants_and_relocation(self):
        with tempfile.TemporaryDirectory() as directory:
            media=pathlib.Path(directory); (media/"torrents/incomplete").mkdir(parents=True)
            for state in ("stoppedUP","pausedUP"):
                item=dict(self.expected,state=state,progress=1.0,amount_left=0,
                          content_path="/data/torrents/.veinfin-download_lifecycle-validation/case/source/fixture.bin")
                q=FakeQbit([[item]],files=[{"name":"fixture.bin","size":len(self.payload),"progress":1.0}])
                torrent,host,_=DOWNLOAD_LIFECYCLE.wait_complete(q,self.hash,"fixture.bin",len(self.payload),media,attempts=1,sleep_fn=lambda _:None)
                self.assertEqual(torrent["state"],state); self.assertIn("/case/source/fixture.bin",str(host))

    def test_missing_or_partial_file_is_rejected(self):
        for files in ([], [{"name":"fixture.bin","size":len(self.payload),"progress":0.5}],
                      [{"name":"fixture.bin","size":len(self.payload),"progress":1.0},{"name":"extra","size":1,"progress":1.0}]):
            with self.assertRaises(RuntimeError):
                DOWNLOAD_LIFECYCLE.validate_single_file(FakeQbit(files=files),self.hash,"fixture.bin",len(self.payload),require_complete=True)

    def test_network_proof_requires_private_trackerless_peerless_zero_transfer(self):
        torrent={"downloaded":0,"downloaded_session":0}
        result=DOWNLOAD_LIFECYCLE.validate_network_isolation(FakeQbit(),self.hash,torrent)
        self.assertEqual(result["external_downloaded_bytes"],0)
        with self.assertRaises(RuntimeError):
            DOWNLOAD_LIFECYCLE.validate_network_isolation(FakeQbit(trackers=[{"url":"https://tracker.invalid"}]),self.hash,torrent)

    def test_hardlink_source_cleanup_preserves_import(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory); source=root/"source"; imported=root/"imported"
            source.write_bytes(self.payload); os.link(source,imported)
            a,b=source.stat(),imported.stat(); self.assertEqual((a.st_dev,a.st_ino),(b.st_dev,b.st_ino)); self.assertGreaterEqual(a.st_nlink,2)
            source.unlink(); self.assertEqual(imported.read_bytes(),self.payload)

    def test_teardown_is_idempotent_after_partial_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            media=pathlib.Path(directory); (media/"torrents/incomplete/.veinfin-download_lifecycle-validation/case").mkdir(parents=True)
            (media/"torrents/.veinfin-download_lifecycle-validation/case").mkdir(parents=True)
            q=FakeQbit([[]])
            DOWNLOAD_LIFECYCLE.teardown_validation(q,[],media); DOWNLOAD_LIFECYCLE.teardown_validation(q,[],media)
            self.assertFalse((media/"torrents/.veinfin-download_lifecycle-validation").exists())


if __name__ == "__main__":
    unittest.main()
