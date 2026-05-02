# surrogate-1 / frontend

### Diagnosis
* The project lacks a robust frontend implementation for handling Hugging Face API rate limits, which can block dataset training.
* The existing frontend implementation may not be reusing existing Lightning Studio instances efficiently, leading to wasted resources.
* The project does not have a clear and concise way to display the most-connected hub (e.g., "MOC") before planning tasks, which can lead to inefficient task planning.
* The frontend does not have a mechanism to bypass the Hugging Face API rate limit by using the CDN tier, which can significantly improve dataset training.
* The project does not have a clear way to display the top hub and related documents for contextual insights, which can lead to poor decision-making.

### Proposed change
The proposed change is to implement a CDN bypass for the Hugging Face API rate limit and reuse existing Lightning Studio instances in the frontend. This will involve modifying the `train.py` file to use the CDN tier for dataset downloads and implementing a mechanism to reuse existing Lightning Studio instances.

### Implementation
To implement the proposed change, the following steps can be taken:
1. Modify the `train.py` file to use the CDN tier for dataset downloads by replacing the `load_dataset` function with a custom function that downloads the dataset from the CDN tier.
2. Implement a mechanism to reuse existing Lightning Studio instances by adding a check to see if a studio with the same name and status already exists before creating a new one.
3. Add a function to display the most-connected hub (e.g., "MOC") before planning tasks.
4. Add a function to display the top hub and related documents for contextual insights.

Example code snippet:
```python
import requests

def download_dataset_from_cdn(repo, path):
    url = f"https://huggingface.co/datasets/{repo}/resolve/main/{path}"
    response = requests.get(url)
    return response.content

def reuse_lightning_studio(studio_name):
    for s in Teamspace.studios:
        if s.name == studio_name and s.status == 'Running':
            return s
    return None

def get_most_connected_hub():
    # Implement logic to get the most-connected hub
    pass

def get_top_hub_and_related_docs():
    # Implement logic to get the top hub and related documents
    pass
```

### Verification
To verify that the proposed change works, the following steps can be taken:
1. Run the modified `train.py` file and verify that the dataset is downloaded from the CDN tier.
2. Verify that existing Lightning Studio instances are reused by checking the studio name and status.
3. Verify that the most-connected hub is displayed correctly.
4. Verify that the top hub and related documents are displayed correctly.
5. Monitor the project's performance and verify that the changes have improved the efficiency of dataset training and task planning.
