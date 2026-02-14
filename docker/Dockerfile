# Custom SageMaker Unified Studio JupyterLab image with pre-commit hooks.
#
# Base image must be sagemaker-distribution >= 2.6 for Unified Studio compatibility.
# See: https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/byoi-specifications.html
#
# Do NOT add ENTRYPOINT — SageMaker manages the entrypoint.
# If you need a custom entrypoint, configure it via ContainerConfig.
# See: https://docs.aws.amazon.com/sagemaker/latest/dg/studio-updated-byoi-how-to-container-configuration.html

FROM public.ecr.aws/sagemaker/sagemaker-distribution:2.6-cpu

ARG NB_USER="sagemaker-user"
ARG NB_UID=1000
ARG NB_GID=100
ENV MAMBA_USER=$NB_USER

USER root

# Install pre-commit
RUN pip install pre-commit

# Create a global git template directory with a post-checkout hook.
# When any user clones a repo that contains .pre-commit-config.yaml,
# this hook fires automatically and installs the pre-commit hook +
# git clean filter — no manual setup.sh needed.
RUN mkdir -p /etc/git-templates/hooks

COPY post-checkout /etc/git-templates/hooks/post-checkout
RUN chmod +x /etc/git-templates/hooks/post-checkout

# Set the global git template so every git clone/init uses it
RUN git config --system init.templateDir /etc/git-templates

USER $MAMBA_USER
