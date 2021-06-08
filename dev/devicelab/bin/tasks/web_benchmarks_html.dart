// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.8

import 'package:flutter_devicelab/framework/framework.dart';
import 'package:flutter_devicelab/tasks/web_benchmarks.dart';

/// Runs all Web benchmarks using the HTML rendering backend.
Future<void> main() async {
  await task(() async {
    return runWebBenchmark(useCanvasKit: false);
  });
}
