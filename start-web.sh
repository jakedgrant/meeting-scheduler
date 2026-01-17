#!/bin/bash
# Quick script to start the web development server

cd "$(dirname "$0")/apps/web"

echo "Starting web development server..."
npm run dev
