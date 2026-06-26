#!/usr/bin/env python3
"""Render a VTC `modelDevelopmentClusters` request body from cluster_config.yaml.

One profile of the fallback chain -> one cluster JSON. This is the single place
that knows how to turn the YAML contract into the v1beta1 API shape, so both the
Terraform path and the notebook path emit byte-identical specs.

Usage:
  # list profile names in fallback order (used by create_cluster.sh to iterate)
  render_cluster_json.py --config configs/cluster_config.yaml --list-profiles

  # render one profile to a JSON file (or stdout if --out is omitted)
  render_cluster_json.py --config configs/cluster_config.yaml \
      --profile a4b200 --out /tmp/vtc_a4b200.json

The only dependency is PyYAML (already present in the Vertex notebook image).
"""

import argparse
import json
import sys

import yaml


def _bucket_name(cfg):
    return cfg["bucket"].get("name") or f'{cfg["project"]["id"]}-vtc-temp'


def _qualified(cfg):
    """Fully-qualified resource names the API wants, derived from the config."""
    p, r, z = cfg["project"]["id"], cfg["project"]["region"], cfg["project"]["zone"]
    net = cfg["network"]
    fs = cfg["filestore"]
    return {
        "network": f'projects/{p}/global/networks/{net["vpc"]}',
        "subnetwork": f'projects/{p}/regions/{r}/subnetworks/{net["subnet"]}',
        "home_storage": (
            f'projects/{p}/locations/{z}/instances/{fs["instance_id"]}'
        ),
        "zone": z,
    }


def _login_pool(cfg):
    """The login node pool — identical across every profile."""
    ln = cfg["login_node"]
    q = _qualified(cfg)
    return {
        "id": "login",
        "machine_spec": {"machine_type": ln["machine_type"]},
        "scaling_spec": {"min_node_count": 1, "max_node_count": 1},
        "enable_public_ips": True,
        "zone": q["zone"],
        "boot_disk": {
            "boot_disk_type": ln["boot_disk_type"],
            "boot_disk_size_gb": ln["boot_disk_size_gb"],
        },
    }


def _worker_pool(cfg, profile):
    """The worker pool for one fallback profile (gpu / tpu / cpu)."""
    q = _qualified(cfg)
    n = profile["node_count"]
    machine_spec = {"machine_type": profile["machine_type"]}

    accel = profile["accelerator"]
    if accel == "gpu":
        machine_spec["accelerator_type"] = profile["accelerator_type"]
        machine_spec["accelerator_count"] = profile["accelerator_count"]
    elif accel == "tpu":
        # TPU rides the GKE orchestrator (Preview): type + topology, no GPU keys.
        machine_spec["tpu_type"] = profile["tpu_type"]
        machine_spec["tpu_topology"] = profile["tpu_topology"]

    # Scarce GPUs (H100/B200) on VTC come from a GCE RESERVATION you create from your
    # quota. Set `reservation: <name>` on the profile to target a SPECIFIC reservation
    # in project.zone; that also forces provisioning_model=RESERVATION below.
    if profile.get("reservation"):
        machine_spec["reservation_affinity"] = {
            "reservationAffinityType": "SPECIFIC_RESERVATION",
            "key": "compute.googleapis.com/reservation-name",
            "values": [
                f'projects/{cfg["project"]["id"]}/zones/{cfg["project"]["zone"]}'
                f'/reservations/{profile["reservation"]}'
            ],
        }

    pool = {
        "id": profile["name"],
        "machine_spec": machine_spec,
        "scaling_spec": {"min_node_count": n, "max_node_count": n},
        "enable_public_ips": True,
        "zone": q["zone"],
        # Worker pools require a boot disk (the API errors without one). GPU machine
        # families (A3/A4) require "hyperdisk-balanced" (pd-standard is rejected, e.g.
        # a4-highgpu-8g); CPU uses pd-standard. Override per profile if needed.
        "boot_disk": {
            "boot_disk_type": profile.get(
                "boot_disk_type",
                "hyperdisk-balanced" if accel == "gpu" else "pd-standard",
            ),
            "boot_disk_size_gb": profile.get("boot_disk_size_gb", 100),
        },
    }
    # GPU node pools REQUIRE provisioning_model (API: "must be set for GPU node
    # pools"); CPU pools must NOT set it. A reservation forces RESERVATION; else GPU
    # defaults to ON_DEMAND. Allow per-profile override. ("STANDARD" is NOT valid.)
    if profile.get("reservation"):
        pool["provisioning_model"] = "RESERVATION"
    elif profile["accelerator"] == "gpu":
        pool["provisioning_model"] = profile.get("provisioning_model", "ON_DEMAND")
    elif profile.get("provisioning_model"):
        pool["provisioning_model"] = profile["provisioning_model"]
    return pool


def render(cfg, profile_name):
    profiles = {p["name"]: p for p in cfg["fallback_chain"]}
    if profile_name not in profiles:
        raise SystemExit(
            f"profile '{profile_name}' not in fallback_chain "
            f"({', '.join(profiles)})"
        )
    profile = profiles[profile_name]
    q = _qualified(cfg)

    worker = _worker_pool(cfg, profile)
    body = {
        "display_name": f'vtc-{cfg["workload"]["model"]}-{profile_name}',
        "network": {"network": q["network"], "subnetwork": q["subnetwork"]},
        "node_pools": [_login_pool(cfg), worker],
    }

    partition = {"id": profile["name"], "node_pool_ids": [profile["name"]]}
    if profile["orchestrator"] == "gke":
        # TPU/Preview path — GKE orchestrator instead of Slurm.
        body["orchestrator_spec"] = {
            "gke_spec": {
                "home_directory_storage": q["home_storage"],
                "partitions": [partition],
            }
        }
    else:
        body["orchestrator_spec"] = {
            "slurm_spec": {
                "home_directory_storage": q["home_storage"],
                "partitions": [partition],
                "login_node_pool_id": "login",
            }
        }
    return body


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--config", required=True, help="path to cluster_config.yaml")
    ap.add_argument("--profile", help="fallback_chain profile name to render")
    ap.add_argument("--out", help="write JSON here (default: stdout)")
    ap.add_argument(
        "--list-profiles",
        action="store_true",
        help="print profile names in fallback order, one per line, then exit",
    )
    args = ap.parse_args(argv)

    with open(args.config) as f:
        cfg = yaml.safe_load(f)

    if args.list_profiles:
        for p in cfg["fallback_chain"]:
            print(p["name"])
        return 0

    if not args.profile:
        ap.error("--profile is required unless --list-profiles is set")

    body = render(cfg, args.profile)
    text = json.dumps(body, indent=2)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text + "\n")
        print(f"wrote {args.out}", file=sys.stderr)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
