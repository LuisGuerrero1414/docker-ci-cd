<?php

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Route;

Route::get('/', function () {
    return view('welcome');
});

Route::get('/health', function () {
    try {
        DB::connection()->getPdo();

        return response()->json([
            'status' => 'ok',
            'db' => 'connected',
        ], 200);
    } catch (\Throwable $e) {
        return response()->json([
            'status' => 'error',
            'db' => 'disconnected',
            'message' => $e->getMessage(),
        ], 500);
    }
});

