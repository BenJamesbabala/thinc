# cython: profile=True
# cython: cdivision=True
# cython: infer_types=True
cimport cython
from libc.string cimport memcpy, memset
from libc.math cimport exp, sqrt
from libc.stdlib cimport calloc, malloc, free

from collections import defaultdict
import numpy

from ..typedefs cimport weight_t


def linear_decay(rate, decay, nr_upd):
    return rate * 1./(1. + decay * nr_upd)


class SGD(object):
    def __init__(self, ops, lr, momentum=0.0, decay=0.0, **settings):
        self.ops = ops
        self.alpha = lr
        self.mu = momentum
        self.decay = decay
        self.max_grad_norm = 100.
        self.momentums = {}
        self.averages = {} if settings.get('averages', True) else None
        self.nr_update = defaultdict(int)

    @property
    def nr_iter(self):
        if not self.nr_update:
            return 0
        return max(self.nr_update.values())

    def __call__(self, weights, gradient, key=None, lr_scale=1.):
        self.nr_update[key] += 1
        nr_upd = self.nr_update[key]
        lr = self.lr(nr_upd)
        lr *= lr_scale
        self.ops.clip_gradient(gradient, self.max_grad_norm)
        if key is None or self.mu == 0.0:
            weights -= lr * gradient
            gradient.fill(0)
        else:
            if key not in self.momentums:
                self.momentums[key] = self.ops.allocate(weights.size)
            momentum = self.momentums[key]
            momentum *= self.mu
            momentum += gradient * lr
            weights -= momentum
            gradient.fill(0)
        if self.averages is not None:
            if key not in self.averages:
                self.averages[key] = self.ops.allocate((weights.size,), dtype='float32')
            self.ops.update_averages(self.averages[key], weights, nr_upd)

    def lr(self, nr_upd):
        return linear_decay(self.alpha, self.decay, nr_upd)

    def set_loss(self, loss):
        pass


class Adam(SGD):
    def __init__(self, ops, lr, L2=1e-4, beta1=0.90, beta2=0.999, eps=1e-08, decay=0.0):
        self.ops = ops
        self.mom1 = {}
        self.mom2 = {}
        self.averages = {}
        self.nr_update = defaultdict(int)
        self.last_seen = defaultdict(int)
        self.max_grad_norm = 100.
        self.alpha = lr
        self.b1 = beta1
        self.b2 = beta2
        self.eps = eps
        self.decay = decay
        self.d = 1.
        self.f = 0.
        self.L2 = L2

    def lr(self, nr_upd):
        alpha = linear_decay(self.alpha, self.decay, nr_upd)
        fix1 = 1.- (self.b1 ** nr_upd)
        fix2 = 1.- (self.b2 ** nr_upd)
        return alpha * numpy.sqrt(fix2) / fix1
    
    def __call__(self, weights, gradient, lr_scale=1., 
            key=None):
        assert key is not None
        assert len(gradient) >= 1
        if key not in self.mom1:
            self.mom1[key] = self.ops.allocate(weights.size)
        if key not in self.mom2:
            self.mom2[key] = self.ops.allocate(weights.size)
        self.nr_update[key] += 1
        nr_upd = self.nr_update[key]
        gradient += self.L2 * weights
        self.ops.clip_gradient(gradient, len(gradient) / 100.)

        mom1 = self.mom1[key]
        mom2 = self.mom2[key]
        cdef weight_t lr = self.lr(nr_upd) * lr_scale
        cdef weight_t b1 = self.b1
        cdef weight_t b2 = self.b1
        cdef weight_t eps = self.eps
        self.ops.adam(
            weights, gradient, mom1, mom2, b1, b2, eps, lr)
        gradient.fill(0)
        #_adam(&weights[0], &gradient[0], &mom1[0], &mom2[0],
        #    weights.shape[0], b1, b2, eps, lr)
        if self.averages is not None:
            if key not in self.averages:
                self.averages[key] = self.ops.allocate((weights.size,), dtype='float32')
            self.ops.update_averages(self.averages[key], weights, nr_upd)

    def set_loss(self, loss):
        pass

class Eve(object):
    def __init__(self, optimizer):
        self.optimizer = optimizer
        self.b3 = 0.999
        self.lower_threshold = 0.1
        self.upper_threshold = 10
        self.d = 1.
        self.f = None

    def __getattr__(self, attr):
        return getattr(self.optimizer, attr)

    def __call__(self, weights, gradient, key=None):
        return self.optimizer(weights, gradient, key=key,
            lr_scale=self.d)

    def set_loss(self, loss):
        if self.f is None:
            self.f = loss
            return
        old_f = self.f
        d = self.d
        c = self._get_c(loss, old_f)
        new_f = c * loss
        r = abs(new_f - old_f) / min(new_f, old_f)
        new_d = d + (1 - self.b3) * (r - d)
        self.d = new_d
        self.f = new_f

    def _get_c(self, loss, old_f):
        if loss < old_f:
            delta = self.lower_threshold + 1.
            Delta = self.upper_threshold + 1.
        else:
            delta = 1. / (self.upper_threshold + 1.)
            Delta = 1. / (self.lower_threshold + 1.)
        return min(max(delta, loss / old_f), delta)
