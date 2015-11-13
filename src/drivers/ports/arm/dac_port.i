/**
 * @file dac_port.i
 * @version 1.0
 *
 * @section License
 * Copyright (C) 2014-2015, Erik Moqvist
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * This file is part of the Simba project.
 */

/* Driver states. */
#define STATE_CONVERTING 0
#define STATE_WAITING    1
#define STATE_EMPTY      2

static void write_next(struct dac_driver_t *drv_p)
{
    drv_p->dev_p->regs_p->PDC.TNPR = (uint32_t)drv_p->next.samples_p;
    drv_p->dev_p->regs_p->PDC.TNCR = drv_p->next.length;
    drv_p->next.length = 0;
}

static void convert_start(struct dac_driver_t *drv_p)
{
    drv_p->dev_p->regs_p->IER = (SAM_DACC_IER_ENDTX | SAM_DACC_IER_TXBUFE);
    drv_p->dev_p->regs_p->CHER = drv_p->chxr;
    write_next(drv_p);
}

static void convert_stop(struct dac_driver_t *drv_p)
{
    drv_p->dev_p->regs_p->IDR = (SAM_DACC_IDR_ENDTX | SAM_DACC_IDR_TXBUFE);
    drv_p->dev_p->regs_p->CHDR = drv_p->chxr;
}

ISR(dacc)
{
    struct dac_device_t *dev_p = &dac_device[0];
    struct dac_driver_t *drv_p = dev_p->jobs.head_p;

    /* Add more samples to the PDC, if any. */
    if (drv_p->next.length > 0) {
        write_next(drv_p);

        /* Resume the waiting thread if it wants to write additional
           samples. */
        if ((drv_p->state == STATE_CONVERTING) &&
            (drv_p->thrd_p != NULL)) {
            thrd_resume_irq(drv_p->thrd_p, 0);
            drv_p->thrd_p = NULL;
        }
    }

    /* Act on empty PDC buffer. */
    if ((dev_p->regs_p->ISR & SAM_DACC_ISR_TXBUFE) != 0) {
        convert_stop(drv_p);

        if (drv_p->state == STATE_WAITING) {
            thrd_resume_irq(drv_p->thrd_p, 0);
            drv_p->thrd_p = NULL;
        } else {
            drv_p->state = STATE_EMPTY;
        }

        /* Dequeue this driver. */
        dev_p->jobs.head_p = drv_p->next_p;

        /* Start converting samples from next driver in queue. */
        if (dev_p->jobs.head_p != NULL) {
            convert_start(dev_p->jobs.head_p);
        }
    }
}

static int dac_port_module_init(void)
{
    return (0);
}

static int dac_port_init(struct dac_driver_t *drv_p,
                         struct dac_device_t *dev_p,
                         struct pin_device_t *pin0_dev_p,
                         struct pin_device_t *pin1_dev_p,
                         long sampling_rate)
{
    uint32_t rc;
    uint32_t mask;
    int channel;

    drv_p->state = STATE_EMPTY;
    drv_p->next.length = 0;
    drv_p->chxr = 0;

    if ((pin0_dev_p == &pin_dac0_dev)
        || (pin1_dev_p == &pin_dac0_dev)) {
        drv_p->chxr |= 0x1;
        
        /* Configure the output pin. */
        mask = pin_dac0_dev.mask;
        pin_dac0_dev.pio_p->PDR = mask;
        pin_dac0_dev.pio_p->ABSR |= mask;
    }
    
    if ((pin1_dev_p == &pin_dac0_dev)
        || (pin1_dev_p == &pin_dac1_dev)) {
        drv_p->chxr |= 0x2;

        /* Configure the output pin. */
        mask = pin_dac1_dev.mask;
        pin_dac1_dev.pio_p->PDR = mask;
        pin_dac1_dev.pio_p->ABSR |= mask;
    }

    /* Setup a Timer Counter to send the clock pulses to the DACC. */
    pmc_peripheral_clock_enable(dev_p->tc.id);

    /* Create a square wave of the desired frequency. UPDOWN_RC
       waveform is a triangle wave starting at zero and increasing to
       the value of the RC register, then it decrements to zero
       again. The tick frequency is MCR / 8, or 10.25 MHz. */
    channel = dev_p->tc.channel;
    dev_p->tc.regs_p->CHANNEL[channel].CMR = (TC_CMR_WAVEFORM_ACPC(2)
                                              | TC_CMR_WAVEFORM_ACPA(1)
                                              | TC_CMR_WAVEFORM_WAVE
                                              | TC_CMR_WAVEFORM_WAVSEL_UP_RC
                                              | TC_CMR_WAVEFORM_TCCLKS(1));
    rc = (F_CPU / 8 / sampling_rate);
    dev_p->tc.regs_p->CHANNEL[channel].RA = (rc / 2);
    dev_p->tc.regs_p->CHANNEL[channel].RC = rc;
    dev_p->tc.regs_p->CHANNEL[channel].CCR = (TC_CCR_SWTRG | TC_CCR_CLKEN);

    /* Setup the DACC clocked by Timer Counter 0, channel 1. */
    pmc_peripheral_clock_enable(dev_p->id);
    nvic_enable_interrupt(dev_p->id);

    dev_p->regs_p->CR = (SAM_DACC_CR_SWRST);
    dev_p->regs_p->MR = (SAM_DACC_MR_REFRESH(8)
                         | SAM_DACC_MR_STARTUP(16)
                         | SAM_DACC_MR_TAG
                         | SAM_DACC_MR_WORD
                         | SAM_DACC_MR_TRGSEL(channel + 1)
                         | SAM_DACC_MR_TRGEN);

    dev_p->regs_p->PDC.PTCR = (PERIPH_PTCR_TXTEN);

    drv_p->dev_p = dev_p;

    return (0);
}

static int dac_port_async_convert(struct dac_driver_t *drv_p,
                                  uint32_t *samples_p,
                                  size_t length)
{
    struct dac_device_t *dev_p = drv_p->dev_p;

    drv_p->state = STATE_CONVERTING;

    /* Enqueue. */
    sys_lock();

    /* Wait if last written data has not yet been written. */
    if (drv_p->next.length > 0) {
        drv_p->thrd_p = thrd_self();
        thrd_suspend_irq(NULL);
    }

    /* Initialize. */
    drv_p->next.samples_p = samples_p;
    drv_p->next.length = length;
    drv_p->next_p = NULL;

    if (dev_p->jobs.head_p != drv_p) {
        if (dev_p->jobs.head_p == NULL) {
            /* Empty queue. */
            dev_p->jobs.head_p = drv_p;
            convert_start(drv_p);
        } else {
            /* Non-empty queue. */
            drv_p->dev_p->jobs.tail_p->next_p = drv_p;
        }
        
        drv_p->dev_p->jobs.tail_p = drv_p;
    }

    sys_unlock();

    return (0);
}

static int dac_port_async_wait(struct dac_driver_t *drv_p)
{
    sys_lock();

    if (drv_p->state == STATE_CONVERTING) {
        drv_p->state = STATE_WAITING;
        drv_p->thrd_p = thrd_self();
        thrd_suspend_irq(NULL);
        drv_p->state = STATE_EMPTY;
    }

    sys_unlock();

    return (0);
}

static int dac_port_convert(struct dac_driver_t *drv_p,
                            uint32_t *samples_p,
                            size_t length)
{
    dac_port_async_convert(drv_p, samples_p, length);
    dac_port_async_wait(drv_p);

    return (0);
}
