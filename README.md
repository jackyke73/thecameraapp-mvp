thecameraapp

iOS camera app with real-time person detection + facial expression recognition.

Requirements
	•	macOS + Xcode (recommended: latest)
	•	iPhone (recommended for testing)
	•	Git LFS (required for the CoreML model)

⸻

Clone the repo (do NOT “Download ZIP”)

Because the emotion model is stored using Git LFS, downloading the repo as a ZIP can give you a fake placeholder file instead of the real .mlmodel.

Use:

git clone https://github.com/jackyke73/thecameraapp.git
cd thecameraapp


⸻

Install Git LFS (required)

macOS (Homebrew)

brew install git-lfs
git lfs install

Then pull the model:

git lfs pull

If the model still looks wrong:

git lfs fetch --all
git lfs checkout


⸻

How to verify the model is actually downloaded

This repo uses a CoreML model file:
	•	CNNEmotions_2.mlmodel

Check its size:

ls -lh CNNEmotions_2.mlmodel

	•	✅ Correct: hundreds of MB
	•	❌ Wrong: a few KB (this means you only have an LFS pointer)

If you suspect you have the pointer file:

head -n 3 CNNEmotions_2.mlmodel

If you see:

version https://git-lfs.github.com/spec/v1

That is NOT the real model. Run:

git lfs pull
git lfs checkout


⸻

If Xcode shows: “unable to deserialize object”

If you open the .mlmodel in Xcode and it says:

There was a problem decoding this Core ML document
validator error: unable to deserialize object

It almost always means: Git LFS did not download the real model, and you opened the pointer file.

Fix:

git lfs pull
git lfs checkout

Then restart Xcode and open the project again.

⸻

For contributors: how the model is stored in LFS

The repo tracks CoreML files via .gitattributes:

*.mlmodel filter=lfs diff=lfs merge=lfs -text

When adding a new model:

git lfs track "*.mlmodel"
git add .gitattributes
git add YourModel.mlmodel
git commit -m "Add CoreML model via LFS"
git push

If you ever need to push all LFS objects:

git lfs push --all origin main


⸻

Common mistakes
	•	❌ Downloading repo as ZIP (often breaks LFS files)
	•	❌ Partner clones without Git LFS installed (gets pointer file)
	•	❌ Opening .mlmodel in Xcode before git lfs pull
