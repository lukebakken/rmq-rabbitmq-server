PROJECT = rabbitmq_aws
PROJECT_DESCRIPTION = A minimalistic AWS API interface used by rabbitmq-autocluster (3.6.x) and other RabbitMQ plugins
PROJECT_MOD = rabbitmq_aws_app
PROJECT_REGISTERED = rabbitmq_aws

define PROJECT_ENV
[]
endef

BUILD_DEPS = rabbit rabbit_common
TEST_DEPS = meck rabbitmq_ct_helpers rabbitmq_ct_client_helpers
LOCAL_DEPS = crypto inets ssl xmerl public_key

PLT_APPS = rabbit

DEP_EARLY_PLUGINS = rabbit_common/mk/rabbitmq-early-plugin.mk
DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk

include ../../rabbitmq-components.mk
include ../../erlang.mk
