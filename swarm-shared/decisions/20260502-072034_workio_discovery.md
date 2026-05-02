# workio / discovery

### High-Value Incremental Improvement for Workio Discovery
#### Task: Implement Knowledge-RAG for Business Research Insights and Integrate with HF CDN Bypass
#### Time Estimate: < 2 hours

### Implementation Plan
#### Step 1: Update `granite-business-research.sh` to Execute Knowledge-RAG
Modify the `granite-business-research.sh` script to execute Knowledge-RAG after running the market analysis script. This will provide contextual insights for business research.
```bash
# granite-business-research.sh
#!/usr/bin/env bash

# Run market analysis script
./market-analysis.sh

# Execute Knowledge-RAG
knowledge-rag --query "top hub and related docs" --context "business research"
```
#### Step 2: Integrate HF CDN Bypass with Knowledge-RAG
Update the `train.py` script to use the HF CDN bypass for dataset training. This will allow for faster dataset downloads and reduce the load on the HF API.
```python
# train.py
import os
import requests

# Define HF CDN URL
hf_cdn_url = "https://huggingface.co/datasets/{repo}/resolve/main/{path}"

# Download dataset using HF CDN bypass
def download_dataset(repo, path):
    url = hf_cdn_url.format(repo=repo, path=path)
    response = requests.get(url)
    with open("dataset.parquet", "wb") as f:
        f.write(response.content)

# Load dataset and train model
download_dataset("my-repo", "my-dataset")
# Train model using downloaded dataset
```
#### Step 3: Reuse Lightning Studio and Avoid Idle Stop
Modify the `train.py` script to reuse the Lightning Studio and avoid idle stop. This will save 80hr/mo quota and prevent training process deaths.
```python
# train.py
import lightning

# Reuse Lightning Studio
for s in lightning.Teamspace.studios:
    if s.name == "my-studio" and s.status == "Running":
        studio = s
        break

# Train model using reused studio
studio.run()
```
By implementing these changes, we can improve the efficiency and effectiveness of the Workio discovery process, while also reducing the load on the HF API and saving quota on Lightning Studio.
