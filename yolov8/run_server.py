"""
API Server Runner
Run this script to start the FastAPI server
"""

import uvicorn
import os
import sys

# Add project root to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

if __name__ == "__main__":
    print("=" * 60)
    print("Tower Classification API Server")
    print("=" * 60)
    print("Starting server at http://localhost:8000")
    print("API Documentation: http://localhost:8000/docs")
    print("=" * 60)

    uvicorn.run(
        "api.main:app",
        host="0.0.0.0",
        port=8000,
        reload=True
    )
