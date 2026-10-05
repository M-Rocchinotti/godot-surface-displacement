// A minimal parallel for over [0, n) with std::thread (the work items are independent).
#pragma once

#include <algorithm>
#include <atomic>
#include <thread>
#include <vector>

namespace gads {

template <typename F>
void parallel_for(size_t n, int threads, F &&fn) {
	if (threads <= 0) {
		threads = int(std::max(1u, std::thread::hardware_concurrency()));
	}
	threads = int(std::min<size_t>(size_t(threads), std::max<size_t>(n / 64, 1)));
	if (threads <= 1) {
		for (size_t i = 0; i < n; i++) {
			fn(i);
		}
		return;
	}
	std::atomic<size_t> next{ 0 };
	auto worker = [&]() {
		for (;;) {
			size_t start = next.fetch_add(64);
			if (start >= n) {
				return;
			}
			size_t end = std::min(n, start + 64);
			for (size_t i = start; i < end; i++) {
				fn(i);
			}
		}
	};
	std::vector<std::thread> pool;
	for (int t = 1; t < threads; t++) {
		pool.emplace_back(worker);
	}
	worker();
	for (std::thread &t : pool) {
		t.join();
	}
}

} // namespace gads
