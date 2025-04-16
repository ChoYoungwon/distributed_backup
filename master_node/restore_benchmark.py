import subprocess
import csv
import re

def run_and_time(cmd):
    print(f"[RUNNING] {' '.join(cmd)}")
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stdout = result.stdout.decode()
    stderr = result.stderr.decode()

    match = re.search(r"\[TIMER\] .*?: ([0-9.]+) seconds", stdout)
    elapsed = float(match.group(1)) if match else -1

    print(f"[DONE] Took {elapsed:.6f} seconds (from binary output)")
    if stdout:
        print("[STDOUT]", stdout)
    if stderr:
        print("[STDERR]", stderr)

    return elapsed

def compare_files(original, restored):
    print(f"[CHECKING] diff {original} {restored}")
    result = subprocess.run(["diff", original, restored])
    if result.returncode == 0:
        print("✅ Restore successful!")
        return True
    else:
        print("❌ Restore failed!")
        return False

def benchmark():
    sizes = [100, 500, 1000, 2000, 3000]

    results = []

    for size in sizes:
        print(f"\n=== [TEST] File Size: {size}MB ===")
        original = f"data_{size}.bin"
        serial_map = f"serial_chunk_map_{size}.json"
        parrel_map = f"parrel_chunk_map_{size}.json"
        serial_out = f"serial_restored_{size}.bin"
        parrel_out = f"parrel_restored_{size}.bin"

        # Serial Restore
        t1 = run_and_time(["./restore", serial_map, serial_out])
        ok1 = compare_files(original, serial_out)

        # Parallel Restore
        t2 = run_and_time(["./parrel_restore", parrel_map, parrel_out])
        ok2 = compare_files(original, parrel_out)

        results.append({
            "file_size_kb": size,
            "serial_restore_time": t1,
            "serial_success": ok1,
            "parrel_restore_time": t2,
            "parrel_success": ok2,
        })

    # Save to CSV
    csv_path = "restore_benchmark_results.csv"
    with open(csv_path, "w", newline="") as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=results[0].keys())
        writer.writeheader()
        for row in results:
            writer.writerow(row)

    print(f"\n✅ Results saved to {csv_path}")

if __name__ == "__main__":
    benchmark()