import subprocess
import time
import csv
import os

def run_and_time(cmd):
    print(f"[RUNNING] {' '.join(cmd)}")
    start = time.time()
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    end = time.time()
    elapsed = end - start
    print(f"[DONE] Took {elapsed:.6f} seconds")
    if result.stdout:
        print("[STDOUT]", result.stdout.decode())
    if result.stderr:
        print("[STDERR]", result.stderr.decode())
    return elapsed

def benchmark():
    sizes = [100, 500, 1000, 2000, 3000]
    nodes = ["172.28.0.11", "9001", "172.28.0.12", "9001", "172.28.0.13", "9001"]
    results = []

    for size in sizes:
        print(f"\n=== [TEST] File Size: {size}MB ===")
        original = f"data_{size}.bin"
        serial_map = f"serial_chunk_map_{size}.json"
        parrel_map = f"parrel_chunk_map_{size}.json"

        # Serial Store
        t1 = run_and_time(["./store", original, serial_map] + nodes)

        # Parallel Store
        t2 = run_and_time(["./parrel_store", original, parrel_map] + nodes)

        results.append({
            "file_size_kb": size,
            "serial_store_time": t1,
            "parrel_store_time": t2,
        })

    # Save to CSV
    csv_path = "store_benchmark_results.csv"
    with open(csv_path, "w", newline="") as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=results[0].keys())
        writer.writeheader()
        for row in results:
            writer.writerow(row)

    print(f"\n✅ Store benchmark results saved to {csv_path}")

if __name__ == "__main__":
    benchmark()